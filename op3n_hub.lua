--[[
	Op3n hub - Anime Adventures
	single file - no external modules - no key system

	RightControl  - show / hide
	drag header   - move

	Boot line: [op3n] hub loaded - N tabs
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
local StarterGui = game:GetService("StarterGui")

local LP = Players.LocalPlayer
local unpack = table.unpack or unpack

while not game:IsLoaded() do task.wait(0.1) end

-- ============================================================
-- generation token - stops old loops when re-pasted
-- ============================================================

local Generation = {}
local Previous = getgenv().Op3nHub
if Previous then
	pcall(function() Previous.dead = true end)
	if Previous.ui then pcall(function() Previous.ui:Destroy() end) end
end
getgenv().Op3nGeneration = Generation

local function alive()
	return getgenv().Op3nGeneration == Generation
end

-- ============================================================
-- util
-- ============================================================

local function new(class, props, parent)
	local object = Instance.new(class)
	for key, value in pairs(props or {}) do
		object[key] = value
	end
	if parent then object.Parent = parent end
	return object
end

local function corner(parent, radius)
	new("UICorner", { CornerRadius = UDim.new(0, radius or 6) }, parent)
end

local function stroke(parent, color, thickness)
	new("UIStroke", {
		Color = color or Color3.fromRGB(45, 45, 55),
		Thickness = thickness or 1,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	}, parent)
end

local function padding(parent, amount)
	new("UIPadding", {
		PaddingTop = UDim.new(0, amount),
		PaddingBottom = UDim.new(0, amount),
		PaddingLeft = UDim.new(0, amount),
		PaddingRight = UDim.new(0, amount),
	}, parent)
end

local function delay(seconds, fn)
	task.spawn(function()
		task.wait(seconds)
		local ok, err = pcall(fn)
		if not ok then warn("[op3n] " .. tostring(err)) end
	end)
end

-- ============================================================
-- theme
-- ============================================================

local Theme = {
	bg = Color3.fromRGB(18, 18, 22),
	panel = Color3.fromRGB(24, 24, 30),
	rail = Color3.fromRGB(15, 15, 19),
	row = Color3.fromRGB(31, 31, 39),
	rowHover = Color3.fromRGB(38, 38, 48),
	accent = Color3.fromRGB(120, 180, 255),
	good = Color3.fromRGB(110, 220, 150),
	bad = Color3.fromRGB(240, 110, 110),
	text = Color3.fromRGB(235, 235, 245),
	dim = Color3.fromRGB(140, 140, 155),
	border = Color3.fromRGB(45, 45, 55),
}

-- ============================================================
-- config
-- ============================================================

local Config = { data = {}, path = "op3n_config.json" }

function Config.load()
	local ok, raw = pcall(function() return readfile(Config.path) end)
	if not ok or type(raw) ~= "string" then return end
	local decoded, result = pcall(function() return HttpService:JSONDecode(raw) end)
	if decoded and type(result) == "table" then Config.data = result end
end

function Config.save()
	pcall(function()
		writefile(Config.path, HttpService:JSONEncode(Config.data))
	end)
end

function Config.get(key, default)
	local value = Config.data[key]
	if value == nil then return default end
	return value
end

function Config.set(key, value)
	Config.data[key] = value
	Config.save()
end

Config.load()

-- ============================================================
-- remotes
-- ============================================================

local R = { map = {} }

do
	local endpoints = ReplicatedStorage:FindFirstChild("endpoints")
	R.c2s = endpoints and endpoints:FindFirstChild("client_to_server")
	R.s2c = endpoints and endpoints:FindFirstChild("server_to_client")
end

function R.get(name)
	local cached = R.map[name]
	if cached and cached.Parent then return cached end
	local object = R.c2s and R.c2s:FindFirstChild(name)
	if object then
		R.map[name] = object
		return object
	end
	return nil
end

function R.event(name)
	return R.s2c and R.s2c:FindFirstChild(name) or nil
end

function R.invoke(name, ...)
	local remote = R.get(name)
	if not remote or not remote:IsA("RemoteFunction") then
		return false, "missing:" .. tostring(name)
	end
	local args = table.pack(...)
	local ok, result = pcall(function()
		return remote:InvokeServer(unpack(args, 1, args.n))
	end)
	return ok, result
end

function R.fire(name, ...)
	local remote = R.get(name)
	if not remote or not remote:IsA("RemoteEvent") then
		return false, "missing:" .. tostring(name)
	end
	local args = table.pack(...)
	local ok, err = pcall(function()
		remote:FireServer(unpack(args, 1, args.n))
	end)
	return ok, err
end

function R.on(name, callback)
	local remote = R.event(name)
	if not remote then return function() end end
	local connection = remote.OnClientEvent:Connect(function(...)
		local ok, err = pcall(callback, ...)
		if not ok then warn("[op3n event " .. name .. "] " .. tostring(err)) end
	end)
	return function()
		if connection then connection:Disconnect() end
	end
end

-- ============================================================
-- bridge - learn remote argument shapes, then replay
-- ============================================================

local Bridge = { learned = {}, targets = {
	"spawn_unit",
	"upgrade_unit_ingame",
	"sell_unit_ingame",
	"change_priority",
	"select_roguelike_option",
	"set_game_finished_vote",
	"vote_wave_skip",
	"use_active_attack",
	"retreat_units",
} }

local targetSet = {}
for _, name in ipairs(Bridge.targets) do targetSet[name] = true end

local function slotKind(value)
	local kind = typeof(value)
	if kind == "CFrame" then return "cframe" end
	if kind == "Vector3" then return "vector" end
	if kind == "number" then return "number" end
	if kind == "string" then return "string" end
	if kind == "Instance" then return "instance" end
	if kind == "boolean" then return "boolean" end
	if kind == "table" then return "table" end
	return "other"
end

local SWAPPABLE = {
	cframe = true, vector = true, number = true, string = true,
	instance = true, boolean = true,
}

do
	if hookmetamethod then
		local originalNamecall
		originalNamecall = hookmetamethod(game, "__namecall", function(self, ...)
			local method = getnamecallmethod()
			if (method == "InvokeServer" or method == "FireServer") and targetSet[tostring(self.Name)] then
				local name = tostring(self.Name)
				local args = table.pack(...)
				local existing = Bridge.learned[name]
				if not existing or existing.count < args.n then
					local slots = {}
					for index = 1, args.n do
						local value = args[index]
						table.insert(slots, { kind = slotKind(value), sample = value })
					end
					Bridge.learned[name] = {
						method = method,
						count = args.n,
						slots = slots,
					}
				end
			end
			return originalNamecall(self, ...)
		end)
	end
end

-- replay a learned call, substituting our own values in slot order
function Bridge.call(name, ...)
	local shape = Bridge.learned[name]
	if not shape then return false, "not-learned" end
	local remote = R.get(name)
	if not remote then return false, "missing-remote" end

	local values = table.pack(...)
	local slot = 1
	local args = {}

	for _, entry in ipairs(shape.slots) do
		local candidate = values[slot]
		if SWAPPABLE[entry.kind] and candidate ~= nil and slotKind(candidate) == entry.kind then
			table.insert(args, candidate)
			slot = slot + 1
		elseif SWAPPABLE[entry.kind] and candidate ~= nil then
			table.insert(args, candidate)
			slot = slot + 1
		else
			table.insert(args, entry.sample)
		end
	end

	local ok, result = pcall(function()
		if shape.method == "FireServer" then
			return remote:FireServer(unpack(args))
		end
		return remote:InvokeServer(unpack(args))
	end)
	return ok, result
end

-- call with the first observed sample, ignoring our values (fallback path)
function Bridge.pass(name)
	return Bridge.call(name)
end

-- ============================================================
-- data
-- ============================================================

local Data = { units = {}, hotbar = {}, currency = nil, phase = "unknown", wave = 0 }

function Data.root()
	return workspace:FindFirstChild("units")
		or workspace:FindFirstChild("Units")
		or workspace:FindFirstChild("game_units")
end

function Data.refreshUnits()
	local list = {}
	local root = Data.root()
	if root then
		for _, object in ipairs(root:GetDescendants()) do
			if object:IsA("Model") then
				local part = object.PrimaryPart or object:FindFirstChildWhichIsA("BasePart")
				if part then
					object.PrimaryPart = part
					table.insert(list, object)
				end
			end
		end
	end
	Data.units = list
	return list
end

function Data.myUnits()
	local mine = {}
	for _, unit in ipairs(Data.units) do
		local owner = unit:GetAttribute("Owner") or unit:GetAttribute("owner")
		if owner == nil or tostring(owner) == LP.Name or owner == LP.UserId then
			table.insert(mine, unit)
		end
	end
	return mine
end

function Data.phaseGuess()
	if workspace:FindFirstChild("lobby_zone") then return "lobby" end
	if workspace:FindFirstChild("ResultsScreen") then return "results" end
	local root = Data.root()
	if root and #root:GetChildren() > 0 then return "match" end
	if LP:GetAttribute("in_game") == true then return "match" end
	return "unknown"
end

-- ============================================================
-- ui engine
-- ============================================================

local Hub = { tabs = {}, actions = {} }
local screen, window, rail, contentArea

local function resolveGuiParent()
	local ok, core = pcall(function() return game:GetService("CoreGui") end)
	if ok and core then return core end
	return LP:FindFirstChild("PlayerGui") or LP:WaitForChild("PlayerGui", 15)
end

local function buildWindow()
	local guiParent = resolveGuiParent()
	if not guiParent then
		warn("[op3n] no gui parent - cannot build window")
		return nil
	end

	screen = new("ScreenGui", {
		Name = "Op3nHub",
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		IgnoreGuiInset = true,
		DisplayOrder = 999,
	}, guiParent)
	Hub.ui = screen

	window = new("Frame", {
		Name = "Main",
		Size = UDim2.fromOffset(680, 440),
		Position = UDim2.new(0.5, -340, 0.5, -220),
		BackgroundColor3 = Theme.bg,
		BorderSizePixel = 0,
		Active = true,
	}, screen)
	corner(window, 10)
	stroke(window, Theme.border)

	local header = new("Frame", {
		Size = UDim2.new(1, 0, 0, 38),
		BackgroundColor3 = Theme.panel,
		BorderSizePixel = 0,
	}, window)
	corner(header, 10)

	new("TextLabel", {
		Text = "Op3n hub",
		Size = UDim2.new(1, -100, 1, 0),
		Position = UDim2.fromOffset(14, 0),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		TextSize = 14,
		TextColor3 = Theme.text,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, header)

	local status = new("TextLabel", {
		Text = "idle",
		Size = UDim2.fromOffset(80, 38),
		Position = UDim2.new(1, -92, 0, 0),
		BackgroundTransparency = 1,
		Font = Enum.Font.Gotham,
		TextSize = 11,
		TextColor3 = Theme.dim,
		TextXAlignment = Enum.TextXAlignment.Right,
	}, header)

	function Hub.status(text, color)
		status.Text = tostring(text)
		status.TextColor3 = color or Theme.dim
	end

	-- drag
	local dragging, dragStart, startPos = false, nil, nil
	header.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			dragging = true
			dragStart = input.Position
			startPos = window.Position
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
			local delta = input.Position - dragStart
			window.Position = UDim2.new(
				startPos.X.Scale, startPos.X.Offset + delta.X,
				startPos.Y.Scale, startPos.Y.Offset + delta.Y
			)
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then dragging = false end
	end)

	-- rail
	rail = new("Frame", {
		Name = "Rail",
		Size = UDim2.new(0, 148, 1, -38),
		Position = UDim2.new(0, 0, 0, 38),
		BackgroundColor3 = Theme.rail,
		BorderSizePixel = 0,
	}, window)

	local railList = new("ScrollingFrame", {
		Name = "Tabs",
		Size = UDim2.new(1, 0, 1, -36),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 2,
		CanvasSize = UDim2.new(0, 0, 0, 0),
	}, rail)
	padding(railList, 6)
	new("UIListLayout", {
		Padding = UDim.new(0, 4),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, railList)
	Hub.railList = railList

	local searchBox = new("TextBox", {
		Size = UDim2.new(1, -12, 0, 24),
		Position = UDim2.new(0, 6, 1, -30),
		BackgroundColor3 = Theme.row,
		BorderSizePixel = 0,
		PlaceholderText = "search...",
		PlaceholderColor3 = Theme.dim,
		Text = "",
		TextColor3 = Theme.text,
		Font = Enum.Font.Gotham,
		TextSize = 12,
		ClearTextOnFocus = false,
	}, rail)
	corner(searchBox, 5)

	local holder = new("Frame", {
		Size = UDim2.new(1, -148, 1, -38),
		Position = UDim2.new(0, 148, 0, 38),
		BackgroundColor3 = Theme.panel,
		BorderSizePixel = 0,
	}, window)

	contentArea = new("Frame", {
		Size = UDim2.new(1, -12, 1, -12),
		Position = UDim2.fromOffset(6, 6),
		BackgroundTransparency = 1,
	}, holder)

	-- RightControl toggle
	UserInputService.InputBegan:Connect(function(input, typing)
		if typing then return end
		if input.KeyCode == Enum.KeyCode.RightControl then
			window.Visible = not window.Visible
		end
	end)

	return searchBox
end

-- ============================================================
-- widget base
-- ============================================================

local Widget = {}

function Widget:wrapper(height)
	local row = new("Frame", {
		Size = UDim2.new(1, 0, 0, height),
		BackgroundColor3 = Theme.row,
		BorderSizePixel = 0,
		ClipsDescendants = true,
	}, self.listFrame)
	corner(row, 5)
	padding(row, 6)
	table.insert(self.rows, row)
	return row
end

function Widget:toggle(config)
	local row = self:wrapper(32)
	local flag = config.flag or (self.key .. "_" .. config.text)

	new("TextLabel", {
		Text = config.text,
		Size = UDim2.new(1, -46, 1, 0),
		BackgroundTransparency = 1,
		Font = Enum.Font.Gotham,
		TextSize = 12,
		TextColor3 = Theme.text,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
	}, row)

	local track = new("Frame", {
		Size = UDim2.fromOffset(36, 18),
		Position = UDim2.new(1, -36, 0.5, -9),
		BackgroundColor3 = Theme.border,
		BorderSizePixel = 0,
	}, row)
	corner(track, 9)

	local knob = new("Frame", {
		Size = UDim2.fromOffset(14, 14),
		Position = UDim2.fromOffset(2, 2),
		BackgroundColor3 = Theme.text,
		BorderSizePixel = 0,
	}, track)
	corner(knob, 7)

	local button = new("TextButton", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Text = "",
	}, track)

	local state = Config.get(flag, config.default or false)

	local function paint(on)
		TweenService:Create(track, TweenInfo.new(0.15), {
			BackgroundColor3 = on and Theme.accent or Theme.border,
		}):Play()
		TweenService:Create(knob, TweenInfo.new(0.15), {
			Position = on and UDim2.fromOffset(20, 2) or UDim2.fromOffset(2, 2),
		}):Play()
	end

	paint(state)
	if state and config.callback then delay(0.1, function() config.callback(true) end) end

	button.MouseButton1Click:Connect(function()
		state = not state
		paint(state)
		Config.set(flag, state)
		if config.callback then
			local ok, err = pcall(config.callback, state)
			if not ok then warn("[op3n toggle] " .. tostring(err)) end
		end
	end)

	return row
end

function Widget:button(config)
	local row = self:wrapper(28)
	local button = new("TextButton", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Text = config.text,
		Font = Enum.Font.GothamMedium,
		TextSize = 12,
		TextColor3 = Theme.text,
	}, row)
	button.MouseEnter:Connect(function() row.BackgroundColor3 = Theme.rowHover end)
	button.MouseLeave:Connect(function() row.BackgroundColor3 = Theme.row end)
	button.MouseButton1Click:Connect(function()
		local ok, err = pcall(config.callback)
		if not ok then
			warn("[op3n button] " .. tostring(err))
			Hub.status("error", Theme.bad)
		end
	end)
	return row
end

function Widget:label(config)
	local row = self:wrapper(config.height or 22)
	row.BackgroundTransparency = 1
	new("TextLabel", {
		Text = config.text,
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Font = Enum.Font.Gotham,
		TextSize = config.size or 11,
		TextColor3 = config.color or Theme.dim,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextWrapped = true,
	}, row)
	return row
end

function Widget:divider()
	local row = self:wrapper(1)
	row.BackgroundColor3 = Theme.border
	return row
end

function Widget:slider(config)
	local row = self:wrapper(44)
	local flag = config.flag or (self.key .. "_" .. config.text)

	new("TextLabel", {
		Text = config.text,
		Size = UDim2.new(1, -60, 0, 16),
		BackgroundTransparency = 1,
		Font = Enum.Font.Gotham,
		TextSize = 12,
		TextColor3 = Theme.text,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, row)

	local readout = new("TextLabel", {
		Text = "",
		Size = UDim2.fromOffset(54, 16),
		Position = UDim2.new(1, -54, 0, 0),
		BackgroundTransparency = 1,
		Font = Enum.Font.Gotham,
		TextSize = 11,
		TextColor3 = Theme.accent,
		TextXAlignment = Enum.TextXAlignment.Right,
	}, row)

	local bar = new("Frame", {
		Size = UDim2.new(1, 0, 0, 5),
		Position = UDim2.new(0, 0, 0, 24),
		BackgroundColor3 = Theme.border,
		BorderSizePixel = 0,
	}, row)
	corner(bar, 3)

	local fill = new("Frame", {
		Size = UDim2.new(0, 0, 1, 0),
		BackgroundColor3 = Theme.accent,
		BorderSizePixel = 0,
	}, bar)
	corner(fill, 3)

	local min = config.min or 0
	local max = config.max or 100
	local step = config.step or 1
	local value = Config.get(flag, config.default or min)
	if value < min then value = min end
	if value > max then value = max end

	local function place(v)
		local ratio = (v - min) / math.max(max - min, 0.0001)
		fill.Size = UDim2.new(ratio, 0, 1, 0)
		if step >= 1 then
			readout.Text = tostring(math.floor(v + 0.5))
		else
			readout.Text = string.format("%.2f", v)
		end
	end

	place(value)
	if config.callback then delay(0.1, function() config.callback(value) end) end

	local dragging = false
	local function apply(input)
		local width = math.max(bar.AbsoluteSize.X, 1)
		local relative = math.clamp((input.Position.X - bar.AbsolutePosition.X) / width, 0, 1)
		local raw = min + relative * (max - min)
		local snapped = math.floor(raw / step + 0.5) * step
		value = math.clamp(snapped, min, max)
		place(value)
	end

	bar.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			dragging = true
			apply(input)
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
			apply(input)
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 or not dragging then return end
		dragging = false
		Config.set(flag, value)
		if config.callback then
			local ok, err = pcall(config.callback, value)
			if not ok then warn("[op3n slider] " .. tostring(err)) end
		end
	end)

	return row
end

function Widget:dropdown(config)
	local options = config.options or {}
	local row = self:wrapper(30)
	local flag = config.flag or (self.key .. "_" .. config.text)

	new("TextLabel", {
		Text = config.text or "",
		Size = UDim2.new(1, -110, 1, 0),
		BackgroundTransparency = 1,
		Font = Enum.Font.Gotham,
		TextSize = 12,
		TextColor3 = Theme.text,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, row)

	local selected = Config.get(flag, config.default or options[1] or "")

	local display = new("TextButton", {
		Size = UDim2.fromOffset(104, 22),
		Position = UDim2.new(1, -104, 0.5, -11),
		BackgroundColor3 = Theme.rail,
		BorderSizePixel = 0,
		Text = tostring(selected) .. "  v",
		Font = Enum.Font.Gotham,
		TextSize = 11,
		TextColor3 = Theme.accent,
		ClipsDescendants = true,
		ZIndex = 4,
	}, row)
	corner(display, 4)

	local popup = new("Frame", {
		Size = UDim2.fromOffset(104, 0),
		Position = UDim2.new(1, -104, 1, 2),
		BackgroundColor3 = Theme.rail,
		BorderSizePixel = 0,
		Visible = false,
		ZIndex = 60,
	}, row)
	corner(popup, 4)
	stroke(popup, Theme.border)

	local list = new("ScrollingFrame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 2,
		CanvasSize = UDim2.new(0, 0, 0, #options * 22),
		ZIndex = 61,
	}, popup)
	padding(list, 3)
	new("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder }, list)

	local open = false

	local function close()
		open = false
		popup.Visible = false
		popup.Size = UDim2.fromOffset(104, 0)
	end

	for _, option in ipairs(options) do
		local item = new("TextButton", {
			Size = UDim2.new(1, 0, 0, 20),
			BackgroundColor3 = Theme.row,
			BorderSizePixel = 0,
			Text = tostring(option),
			Font = Enum.Font.Gotham,
			TextSize = 11,
			TextColor3 = Theme.text,
			ZIndex = 62,
		}, list)
		corner(item, 3)
		item.MouseButton1Click:Connect(function()
			selected = option
			display.Text = tostring(option) .. "  v"
			Config.set(flag, option)
			close()
			if config.callback then
				local ok, err = pcall(config.callback, option)
				if not ok then warn("[op3n dropdown] " .. tostring(err)) end
			end
		end)
	end

	display.MouseButton1Click:Connect(function()
		open = not open
		if open then
			local abs = display.AbsolutePosition
			local size = display.AbsoluteSize
			-- parent to the screen so nothing clips the popup
			popup.Parent = screen
			popup.Position = UDim2.fromOffset(abs.X, abs.Y + size.Y + 2)
			popup.Size = UDim2.fromOffset(104, math.min(#options * 22 + 8, 150))
			popup.Visible = true
		else
			close()
		end
	end)

	UserInputService.InputBegan:Connect(function(input)
		if not open or input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
		local position = input.Position
		local topLeft = popup.AbsolutePosition
		local bottomRight = topLeft + popup.AbsoluteSize
		local onDisplay = display.AbsolutePosition
		local displayEnd = onDisplay + display.AbsoluteSize
		local insidePopup = position.X >= topLeft.X and position.X <= bottomRight.X
			and position.Y >= topLeft.Y and position.Y <= bottomRight.Y
		local insideDisplay = position.X >= onDisplay.X and position.X <= displayEnd.X
			and position.Y >= onDisplay.Y and position.Y <= displayEnd.Y
		if not insidePopup and not insideDisplay then close() end
	end)

	return row
end

function Widget:input(config)
	local row = self:wrapper(30)
	local flag = config.flag or (self.key .. "_" .. config.text)

	new("TextLabel", {
		Text = config.text or "",
		Size = UDim2.new(1, -130, 1, 0),
		BackgroundTransparency = 1,
		Font = Enum.Font.Gotham,
		TextSize = 12,
		TextColor3 = Theme.text,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, row)

	local box = new("TextBox", {
		Size = UDim2.fromOffset(124, 22),
		Position = UDim2.new(1, -124, 0.5, -11),
		BackgroundColor3 = Theme.rail,
		BorderSizePixel = 0,
		Text = tostring(Config.get(flag, config.default or "")),
		PlaceholderText = config.placeholder or "",
		PlaceholderColor3 = Theme.dim,
		TextColor3 = Theme.text,
		Font = Enum.Font.Gotham,
		TextSize = 11,
		ClearTextOnFocus = false,
	}, row)
	corner(box, 4)

	box.FocusLost:Connect(function()
		Config.set(flag, box.Text)
		if config.callback then
			local ok, err = pcall(config.callback, box.Text)
			if not ok then warn("[op3n input] " .. tostring(err)) end
		end
	end)

	return row
end

function Widget:keybind(config)
	local row = self:wrapper(30)
	local flag = self.key .. "_key_" .. config.text

	new("TextLabel", {
		Text = config.text,
		Size = UDim2.new(1, -70, 1, 0),
		BackgroundTransparency = 1,
		Font = Enum.Font.Gotham,
		TextSize = 12,
		TextColor3 = Theme.text,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, row)

	local button = new("TextButton", {
		Size = UDim2.fromOffset(64, 22),
		Position = UDim2.new(1, -64, 0.5, -11),
		BackgroundColor3 = Theme.rail,
		BorderSizePixel = 0,
		Text = tostring(Config.get(flag, config.default or "None")),
		Font = Enum.Font.Gotham,
		TextSize = 11,
		TextColor3 = Theme.accent,
	}, row)
	corner(button, 4)

	local listening = false
	button.MouseButton1Click:Connect(function()
		listening = true
		button.Text = "..."
	end)

	UserInputService.InputBegan:Connect(function(input, typing)
		if typing or not listening then return end
		if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
		listening = false
		button.Text = input.KeyCode.Name
		Config.set(flag, input.KeyCode.Name)
		if config.callback then pcall(config.callback, input.KeyCode.Name) end
	end)

	return row
end

function Widget:list(config)
	local items = config.items or {}
	local saved = Config.get(config.flag or (self.key .. "_list"), items)
	local order = {}
	for index, item in ipairs(items) do
		order[index] = saved[index] or item
	end

	local row = self:wrapper(math.min(#items * 22 + 20, 190))
	local container = new("Frame", {
		Size = UDim2.new(1, 0, 1, -16),
		Position = UDim2.fromOffset(0, 16),
		BackgroundTransparency = 1,
	}, row)
	new("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder }, container)

	local built = {}

	local function refresh()
		for _, object in ipairs(built) do object:Destroy() end
		built = {}
		for index, item in ipairs(order) do
			local line = new("Frame", {
				Size = UDim2.new(1, 0, 0, 20),
				BackgroundColor3 = Theme.rail,
				BorderSizePixel = 0,
				LayoutOrder = index,
			}, container)
			corner(line, 3)

			new("TextLabel", {
				Text = tostring(item),
				Size = UDim2.new(1, -46, 1, 0),
				Position = UDim2.fromOffset(4, 0),
				BackgroundTransparency = 1,
				Font = Enum.Font.Gotham,
				TextSize = 11,
				TextColor3 = Theme.text,
				TextXAlignment = Enum.TextXAlignment.Left,
			}, line)

			local up = new("TextButton", {
				Text = "^",
				Size = UDim2.fromOffset(20, 16),
				Position = UDim2.new(1, -44, 0.5, -8),
				BackgroundColor3 = Theme.row,
				BorderSizePixel = 0,
				Font = Enum.Font.GothamBold,
				TextSize = 11,
				TextColor3 = Theme.accent,
			}, line)
			corner(up, 3)

			local down = new("TextButton", {
				Text = "v",
				Size = UDim2.fromOffset(20, 16),
				Position = UDim2.new(1, -22, 0.5, -8),
				BackgroundColor3 = Theme.row,
				BorderSizePixel = 0,
				Font = Enum.Font.GothamBold,
				TextSize = 11,
				TextColor3 = Theme.accent,
			}, line)
			corner(down, 3)

			up.MouseButton1Click:Connect(function()
				if index <= 1 then return end
				order[index], order[index - 1] = order[index - 1], order[index]
				Config.set(config.flag or (self.key .. "_list"), order)
				refresh()
				if config.callback then pcall(config.callback, order) end
			end)

			down.MouseButton1Click:Connect(function()
				if index >= #order then return end
				order[index], order[index + 1] = order[index + 1], order[index]
				Config.set(config.flag or (self.key .. "_list"), order)
				refresh()
				if config.callback then pcall(config.callback, order) end
			end)

			table.insert(built, line)
		end
	end

	refresh()
	return row
end

-- ============================================================
-- section
-- ============================================================

local Section = {}
Section.__index = Section
setmetatable(Section, { __index = Widget })  -- sections inherit every widget method

function Section.new(parent, title, collapsed)
	local self = setmetatable({ rows = {}, key = tostring(title) }, Section)

	local frame = new("Frame", {
		Size = UDim2.new(1, 0, 0, 26),
		BackgroundColor3 = Theme.row,
		BorderSizePixel = 0,
		ClipsDescendants = true,
	}, parent)
	corner(frame, 6)
	self.frame = frame

	local headerButton = new("TextButton", {
		Size = UDim2.new(1, 0, 0, 26),
		BackgroundTransparency = 1,
		Text = "",
		ZIndex = 2,
	}, frame)

	local chevron = new("TextLabel", {
		Text = collapsed and ">" or "v",
		Size = UDim2.fromOffset(20, 26),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		TextSize = 11,
		TextColor3 = Theme.dim,
		ZIndex = 3,
	}, frame)

	new("TextLabel", {
		Text = title,
		Size = UDim2.new(1, -28, 0, 26),
		Position = UDim2.fromOffset(22, 0),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamMedium,
		TextSize = 12,
		TextColor3 = Theme.text,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 3,
	}, frame)

	local list = new("Frame", {
		Size = UDim2.new(1, 0, 0, 0),
		Position = UDim2.fromOffset(0, 26),
		BackgroundTransparency = 1,
		ZIndex = 2,
	}, frame)
	padding(list, 4)
	new("UIListLayout", { Padding = UDim.new(0, 3), SortOrder = Enum.SortOrder.LayoutOrder }, list)
	self.listFrame = list
	self.open = not collapsed

	local function resize()
		local height = 0
		if self.open then
			height = list.UIListLayout.AbsoluteContentSize.Y + 8
		end
		list.Size = UDim2.new(1, 0, 0, height)
		frame.Size = UDim2.new(1, 0, 0, 26 + height)
		chevron.Text = self.open and "v" or ">"
	end

	list.UIListLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(resize)
	headerButton.MouseButton1Click:Connect(function()
		self.open = not self.open
		resize()
	end)

	resize()
	return self
end

function Section.filter(self, query)
	query = string.lower(query or "")
	for _, row in ipairs(self.rows) do
		if query == "" then
			row.Visible = true
		else
			local texts = {}
			for _, child in ipairs(row:GetChildren()) do
				if child:IsA("TextLabel") or child:IsA("TextButton") or child:IsA("TextBox") then
					table.insert(texts, string.lower(child.Text or ""))
				end
			end
			row.Visible = string.find(table.concat(texts, " "), query, 1, true) ~= nil
		end
	end
end

-- ============================================================
-- group
-- ============================================================

local Group = {}
Group.__index = Group

function Group.new(parent)
	local self = setmetatable({ sections = {}, count = 0 }, Group)

	local holder = new("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Visible = false,
	}, parent)
	self.frame = holder

	local left = new("ScrollingFrame", {
		Size = UDim2.new(0.5, -4, 1, 0),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 2,
		CanvasSize = UDim2.new(0, 0, 0, 0),
	}, holder)
	new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, left)

	local right = new("ScrollingFrame", {
		Size = UDim2.new(0.5, -4, 1, 0),
		Position = UDim2.new(0.5, 4, 0, 0),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 2,
		CanvasSize = UDim2.new(0, 0, 0, 0),
	}, holder)
	new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, right)

	self.left, self.right = left, right

	left.UIListLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
		left.CanvasSize = UDim2.new(0, 0, 0, left.UIListLayout.AbsoluteContentSize.Y + 10)
	end)
	right.UIListLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
		right.CanvasSize = UDim2.new(0, 0, 0, right.UIListLayout.AbsoluteContentSize.Y + 10)
	end)

	return self
end

function Group:section(title, collapsed, column)
	local target
	if column then
		target = (column == 2) and self.right or self.left
	else
		self.count = self.count + 1
		target = (self.count % 2 == 1) and self.left or self.right
	end
	local section = Section.new(target, title, collapsed)
	table.insert(self.sections, section)
	return section
end

function Hub:addTab(name)
	local button = new("TextButton", {
		Size = UDim2.new(1, 0, 0, 28),
		BackgroundColor3 = Theme.row,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Text = "  " .. name,
		Font = Enum.Font.Gotham,
		TextSize = 12,
		TextColor3 = Theme.dim,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, Hub.railList)
	corner(button, 5)
	button.LayoutOrder = #Hub.tabs + 1

	local group = Group.new(contentArea)
	local tab = { name = name, button = button, group = group }
	table.insert(Hub.tabs, tab)

	button.MouseButton1Click:Connect(function() Hub.selectTab(name) end)
	button.MouseEnter:Connect(function()
		if tab.active then return end
		button.BackgroundTransparency = 0
		button.TextColor3 = Theme.text
	end)
	button.MouseLeave:Connect(function()
		if tab.active then return end
		button.BackgroundTransparency = 1
		button.TextColor3 = Theme.dim
	end)

	return group
end

function Hub.selectTab(name)
	for _, tab in ipairs(Hub.tabs) do
		local active = tab.name == name
		tab.active = active
		tab.group.frame.Visible = active
		tab.button.BackgroundTransparency = active and 0 or 1
		tab.button.TextColor3 = active and Theme.accent or Theme.dim
	end
end

-- ============================================================
-- placement
-- ============================================================

local Placement = { front = nil, finish = nil, nextIndex = 1 }

function Placement.groundAt(x, z)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local exclude = {}
	if LP.Character then table.insert(exclude, LP.Character) end
	params.FilterDescendantsInstances = exclude

	local result = workspace:Raycast(Vector3.new(x, 300, z), Vector3.new(0, -600, 0), params)
	if not result then return nil end
	if result.Normal.Y < 0.55 then return nil end
	local lift = result.Normal.Y > 0.95 and 1.5 or 1.0
	return CFrame.new(result.Position + Vector3.new(0, lift, 0))
end

function Placement.anchor(which)
	local character = LP.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		Hub.status("no character", Theme.bad)
		return false
	end
	local spot = Vector3.new(root.Position.X, 0, root.Position.Z)
	if which == "front" then
		Placement.front = spot
	else
		Placement.finish = spot
	end
	Hub.status(which .. " set", Theme.good)
	return true
end

function Placement.spotAt(ratio)
	if not Placement.front or not Placement.finish then return nil end
	local x = Placement.front.X + (Placement.finish.X - Placement.front.X) * ratio
	local z = Placement.front.Z + (Placement.finish.Z - Placement.front.Z) * ratio

	local cframe = Placement.groundAt(x, z)
	if cframe then return cframe end

	for step = 1, 10 do
		for _, sign in ipairs({ 1, -1 }) do
			local probe = Placement.groundAt(x + sign * step * 2, z)
			if probe then return probe end
		end
	end
	return nil
end

function Placement.place(unitId, ratio)
	local cframe = Placement.spotAt(ratio)
	if not cframe then
		Hub.status("no ground", Theme.bad)
		return false
	end
	local ok = Bridge.call("spawn_unit", unitId, cframe)
	if ok then
		Hub.status("placed", Theme.good)
	else
		Hub.status("teach bridge", Theme.bad)
	end
	return ok
end

function Placement.marker()
	local cframe = Placement.spotAt(Config.get("place_ratio", 0.5))
	if not cframe then
		Hub.status("no ground", Theme.bad)
		return
	end
	local part = new("Part", {
		Size = Vector3.new(2, 2, 2),
		Anchored = true,
		CanCollide = false,
		Transparency = 0.5,
		Color = Theme.accent,
		Material = Enum.Material.Neon,
		CFrame = cframe,
	}, workspace)
	delay(3, function() part:Destroy() end)
end

-- ============================================================
-- cards
-- ============================================================

local Cards = {
	buffs = {
		"Boss Damage", "Attack", "Cooldown", "Double Attack", "Range",
		"Active Cooldown", "Yen", "Double Attack/Double Cooldown",
		"Gain 2 Random Effects", "Random Blessings", "Double Range",
		"Double Attack/Half Range",
	},
	curses = {
		"Enemy Health", "Enemy Regen", "Enemy Shield", "Resistant",
		"Plated", "Explosive Deaths", "Enemy Speed", "Random Curses", "New Path",
	},
	mode = "Balanced",
	maxCurses = 4,
	fromWave = 13,
	untilWave = 20,
	wave = 0,
	taken = 0,
}

function Cards.rank(name)
	name = tostring(name or "")
	for index, buff in ipairs(Cards.buffs) do
		if string.find(name, buff, 1, true) then return 100 - index end
	end
	for index, curse in ipairs(Cards.curses) do
		if string.find(name, curse, 1, true) then return -index end
	end
	return -999
end

function Cards.isCurse(name)
	for _, curse in ipairs(Cards.curses) do
		if string.find(tostring(name or ""), curse, 1, true) then return true end
	end
	return false
end

function Cards.want(name)
	if not Cards.isCurse(name) then return true end
	if Cards.mode == "Safe" then return false end
	if Cards.mode == "Greedy" then return true end
	if Cards.taken >= Cards.maxCurses then return false end
	if Cards.wave < Cards.fromWave or Cards.wave > Cards.untilWave then return false end
	return true
end

function Cards.choose(options)
	local best, bestScore = nil, -math.huge
	for index, option in ipairs(options) do
		local name = type(option) == "table"
			and (option.name or option.Name or option.label or option.text)
			or tostring(option)
		if Cards.want(name) then
			local score = Cards.rank(name)
			if score > bestScore then
				best, bestScore = index, score
			end
		end
	end
	return best
end

function Cards.pickOptions(options)
	local index = Cards.choose(options)
	if not index then return false end
	local name = type(options[index]) == "table"
		and (options[index].name or options[index].Name or options[index].label)
		or options[index]
	if Cards.isCurse(name) then Cards.taken = Cards.taken + 1 end
	return Bridge.call("select_roguelike_option", index)
end

R.on("wave_started", function(wave)
	Cards.wave = tonumber(wave) or (Cards.wave + 1)
end)

R.on("show_roguelike_options", function(options)
	if not Config.get("cards_auto", false) then return end
	if type(options) ~= "table" then return end
	delay(1.2, function() Cards.pickOptions(options) end)
end)

-- ============================================================
-- autoplay
-- ============================================================

local AutoPlay = {
	running = false,
	phase = "unknown",
	runs = 0,
	limitRuns = 0,
	limitMinutes = 0,
	started = os.clock(),
}

function AutoPlay.setPhase(phase)
	if AutoPlay.phase == phase then return end
	AutoPlay.phase = phase
	Hub.status(phase, Theme.accent)
end

function AutoPlay.start()
	AutoPlay.running = true
	AutoPlay.started = os.clock()
	Hub.status("running", Theme.good)
end

function AutoPlay.stop()
	AutoPlay.running = false
	Hub.status("idle", Theme.dim)
end

function AutoPlay.tick()
	if not AutoPlay.running then return end

	if AutoPlay.limitRuns > 0 and AutoPlay.runs >= AutoPlay.limitRuns then
		AutoPlay.stop()
		Hub.status("run limit", Theme.good)
		return
	end
	if AutoPlay.limitMinutes > 0 and (os.clock() - AutoPlay.started) / 60 >= AutoPlay.limitMinutes then
		AutoPlay.stop()
		Hub.status("time limit", Theme.good)
		return
	end

	local phase = Data.phaseGuess()
	AutoPlay.setPhase(phase)

	if phase == "results" then
		if Config.get("auto_replay", true) then
			Bridge.call("set_game_finished_vote", true)
		end
		AutoPlay.runs = AutoPlay.runs + 1
	elseif phase == "lobby" then
		if Config.get("auto_start", true) then
			R.invoke("request_start_game")
		end
	elseif phase == "match" then
		if Config.get("auto_skip", false) then
			Bridge.call("vote_wave_skip")
		end
		if Config.get("auto_place", false) then
			Placement.tick()
		end
		if Config.get("auto_upgrade", false) then
			for _, unit in ipairs(Data.myUnits()) do
				Bridge.call("upgrade_unit_ingame", unit)
			end
		end
	end
end

function Placement.tick()
	if Placement.locked then return end
	Placement.locked = true
	task.spawn(function()
		task.wait(Config.get("place_delay", 1))
		Placement.locked = false
	end)

	local hotbar = Data.hotbar
	if #hotbar == 0 then
		Data.scanHotbar()
		hotbar = Data.hotbar
	end
	if #hotbar == 0 then return end

	local slot = hotbar[Placement.nextIndex] or hotbar[1]
	if not slot then return end

	local affordable = true
	if slot.cost and Data.currency then
		affordable = Data.currency >= slot.cost
	end
	if not affordable then return end

	if Placement.place(slot.id or slot.name or slot.index, Config.get("place_ratio", 0.5)) then
		Placement.nextIndex = Placement.nextIndex + 1
		if Placement.nextIndex > #hotbar then Placement.nextIndex = 1 end
	end
end

-- ============================================================
-- hotbar + currency scan
-- ============================================================

function Data.scanHotbar()
	local found = {}
	local playerGui = LP:FindFirstChild("PlayerGui")
	if not playerGui then return found end

	local claimed = {}
	for _, label in ipairs(playerGui:GetDescendants()) do
		if label:IsA("TextLabel") then
			local text = label.Text or ""
			local level = string.match(text, "Lvl%s*(%d+)")
			-- \194\165 is the yen sign in UTF-8 bytes
			local costText = string.match(text, "([%d,]+)%s*\194\165")
			if level or costText then
				local node = label
				local depth = 0
				while node and depth < 7 do
					if node:IsA("TextButton") or node:IsA("ImageButton") then break end
					node = node.Parent
					depth = depth + 1
				end
				if node and not claimed[node] then
					claimed[node] = true
					table.insert(found, {
						button = node,
						level = tonumber(level),
						cost = costText and tonumber((costText:gsub(",", ""))),
						text = text,
					})
				end
			end
		end
	end

	table.sort(found, function(a, b)
		local ax = a.button.AbsolutePosition.X + a.button.AbsolutePosition.Y * 1000
		local bx = b.button.AbsolutePosition.X + b.button.AbsolutePosition.Y * 1000
		return ax < bx
	end)

	for index, slot in ipairs(found) do slot.index = index end
	Data.hotbar = found
	return found
end

function Data.scanCurrency()
	local playerGui = LP:FindFirstChild("PlayerGui")
	if not playerGui then return nil end
	local best = nil
	for _, label in ipairs(playerGui:GetDescendants()) do
		if label:IsA("TextLabel") then
			local clean = (label.Text or ""):gsub(",", "")
			local value = tonumber(clean)
			if value and value > 0 and #clean <= 9 and label.AbsoluteSize.X < 400 then
				if not best or value > best then best = value end
			end
		end
	end
	Data.currency = best
	return best
end

-- ============================================================
-- webhook
-- ============================================================

local Webhook = { queue = {}, url = "" }

function Webhook.send(payload)
	if Webhook.url == "" then return false end
	local body = HttpService:JSONEncode(payload)
	local ok = pcall(function()
		request({
			Url = Webhook.url,
			Method = "POST",
			Headers = { ["Content-Type"] = "application/json" },
			Body = body,
		})
	end)
	return ok
end

function Webhook.push(name, value)
	table.insert(Webhook.queue, { name = tostring(name), value = tostring(value), inline = true })
end

function Webhook.flush(title)
	if #Webhook.queue == 0 then return end
	local fields = {}
	for _, entry in ipairs(Webhook.queue) do table.insert(fields, entry) end
	Webhook.queue = {}
	Webhook.send({
		embeds = { {
			title = title or "Match log",
			color = 3066993,
			author = { name = "Op3n hub" },
			fields = fields,
			footer = { text = os.date("%Y-%m-%d %H:%M:%S") },
		} },
	})
end

R.on("game_finished", function()
	if not Config.get("webhook_match", true) then return end
	Webhook.push("Match", "finished")
	Webhook.push("Runs", AutoPlay.runs)
	delay(2, function() Webhook.flush("Match result") end)
end)

R.on("loot_spawned", function(name)
	if not Config.get("webhook_rare", false) then return end
	Webhook.push("Drop", tostring(name or "loot"))
end)

-- ============================================================
-- build ui
-- ============================================================

local searchBox = buildWindow()

if not searchBox then
	warn("[op3n] window build failed - aborting")
	return
end

-- each tab is isolated: one failing tab cannot kill the rest
local function tab(name, builder)
	local ok, err = pcall(function()
		local group = Hub:addTab(name)
		builder(group)
	end)
	if not ok then
		warn("[op3n] tab '" .. name .. "' failed: " .. tostring(err))
	end
end

-- ---------------- Main ----------------

tab("Main", function(group)
	local session = group:section("Session", false)
	session:label({ text = "place id: " .. tostring(game.PlaceId) })
	session:label({ text = "remotes: " .. (R.c2s and "found" or "MISSING") })
	session:label({ text = "bridge: learning from live calls" })
	session:button({
		text = "Refresh state",
		callback = function()
			Data.refreshUnits()
			Data.scanHotbar()
			Data.scanCurrency()
			Hub.status("refreshed", Theme.good)
		end,
	})

	local quick = group:section("Quick actions", false)
	quick:button({ text = "Start match", callback = function() R.invoke("request_start_game") end })
	quick:button({ text = "Skip wave", callback = function() Bridge.call("vote_wave_skip") end })
	quick:button({ text = "Back to lobby", callback = function() R.invoke("teleport_back_to_lobby") end })
	quick:button({ text = "Retreat units", callback = function() Bridge.call("retreat_units") end })

	local bridge = group:section("Remote bridge", false)
	bridge:label({ text = "Play one match by hand to teach every remote shape." })
	bridge:button({
		text = "Print learned shapes",
		callback = function()
			print("--- learned shapes ---")
			for _, name in ipairs(Bridge.targets) do
				local shape = Bridge.learned[name]
				if shape then
					local kinds = {}
					for _, slot in ipairs(shape.slots) do table.insert(kinds, slot.kind) end
					print(string.format("  %-30s %s(%s)", name, shape.method, table.concat(kinds, ", ")))
				else
					print(string.format("  %-30s -", name))
				end
			end
		end,
	})
	bridge:button({
		text = "Save learned shapes",
		callback = function()
			local lines = {}
			for _, name in ipairs(Bridge.targets) do
				local shape = Bridge.learned[name]
				if shape then
					local kinds = {}
					for _, slot in ipairs(shape.slots) do table.insert(kinds, slot.kind) end
					table.insert(lines, name .. " " .. shape.method .. "(" .. table.concat(kinds, ", ") .. ")")
				else
					table.insert(lines, name .. " -")
				end
			end
			writefile("op3n_shapes.txt", table.concat(lines, "\n"))
			print("[op3n] saved op3n_shapes.txt")
		end,
	})

	local stats = group:section("Live readout", false)
	stats:label({ text = "unit count and currency refresh every 2s." })
	stats:button({
		text = "Print current state",
		callback = function()
			print("[op3n] units:", #Data.units, "hotbar:", #Data.hotbar,
				"currency:", Data.currency, "phase:", AutoPlay.phase, "runs:", AutoPlay.runs)
		end,
	})
end)

-- ---------------- AutoPlay ----------------

tab("AutoPlay", function(group)
	local run = group:section("Run", false)
	run:toggle({
		text = "Auto run", flag = "auto_run",
		callback = function(on)
			if on then AutoPlay.start() else AutoPlay.stop() end
		end,
	})
	run:toggle({ text = "Start match automatically", flag = "auto_start", default = true })
	run:toggle({ text = "Replay automatically", flag = "auto_replay", default = true })
	run:toggle({ text = "Skip waves", flag = "auto_skip", default = false })

	local place = group:section("Placement in loop", false)
	place:toggle({ text = "Auto place units", flag = "auto_place", default = false })
	place:toggle({ text = "Auto upgrade units", flag = "auto_upgrade", default = false })
	place:slider({
		text = "Place delay (s)", flag = "place_delay",
		min = 0.2, max = 5, step = 0.2, default = 1,
	})

	local limits = group:section("Limits", false)
	limits:slider({
		text = "Run limit (0 = off)", flag = "auto_limit_runs",
		min = 0, max = 100, step = 1, default = 0,
		callback = function(value) AutoPlay.limitRuns = value end,
	})
	limits:slider({
		text = "Minute limit (0 = off)", flag = "auto_limit_minutes",
		min = 0, max = 480, step = 5, default = 0,
		callback = function(value) AutoPlay.limitMinutes = value end,
	})
	limits:button({
		text = "Reset run counter",
		callback = function()
			AutoPlay.runs = 0
			Hub.status("counter reset", Theme.good)
		end,
	})
end)

-- ---------------- Placement ----------------

tab("Placement", function(group)
	local anchors = group:section("Anchors", false)
	anchors:label({ text = "Stand at the front of the lane, press set. Repeat at the end." })
	anchors:button({ text = "Set front anchor", callback = function() Placement.anchor("front") end })
	anchors:button({ text = "Set end anchor", callback = function() Placement.anchor("finish") end })
	anchors:button({ text = "Show marker at ratio", callback = function() Placement.marker() end })

	local settings = group:section("Settings", false)
	settings:slider({
		text = "Lane ratio", flag = "place_ratio",
		min = 0, max = 1, step = 0.05, default = 0.5,
	})
	settings:dropdown({
		text = "Zone", flag = "place_zone",
		options = { "Front", "Mid", "End", "Spread" }, default = "Mid",
		callback = function(value)
			local ratios = { Front = 0.15, Mid = 0.5, End = 0.85, Spread = 0.5 }
			Config.set("place_ratio", ratios[value] or 0.5)
		end,
	})
	settings:button({
		text = "Place one unit now",
		callback = function()
			local hotbar = Data.scanHotbar()
			if #hotbar == 0 then
				Hub.status("no hotbar", Theme.bad)
				return
			end
			Placement.place(hotbar[1].index, Config.get("place_ratio", 0.5))
		end,
	})
end)

-- ---------------- Cards ----------------

tab("Cards", function(group)
	local mode = group:section("Mode", false)
	mode:dropdown({
		text = "Card mode", flag = "cards_mode",
		options = { "Safe", "Balanced", "Greedy" }, default = "Balanced",
		callback = function(value) Cards.mode = value end,
	})
	mode:toggle({
		text = "Auto pick cards", flag = "cards_auto",
		callback = function(on) Cards.auto = on end,
	})
	mode:slider({
		text = "Max curses", flag = "cards_max_curses",
		min = 0, max = 9, step = 1, default = 4,
		callback = function(value) Cards.maxCurses = value end,
	})
	mode:slider({
		text = "Curses from wave", flag = "cards_from",
		min = 1, max = 30, step = 1, default = 13,
		callback = function(value) Cards.fromWave = value end,
	})
	mode:slider({
		text = "Curses until wave", flag = "cards_until",
		min = 1, max = 30, step = 1, default = 20,
		callback = function(value) Cards.untilWave = value end,
	})
	mode:button({
		text = "Reset curse counter",
		callback = function()
			Cards.taken = 0
			Hub.status("curses reset", Theme.good)
		end,
	})

	local buffs = group:section("Buff ranking", false)
	buffs:list({ text = "best first", items = Cards.buffs, flag = "cards_buff_order" })

	local curses = group:section("Curse ranking", false)
	curses:list({ text = "least bad first", items = Cards.curses, flag = "cards_curse_order" })
end)

-- ---------------- Farm ----------------

tab("Farm", function(group)
	local maps = group:section("Maps", false)
	maps:dropdown({
		text = "Farm map", flag = "farm_map",
		options = { "Bulmy", "Sprintwagon", "Custom" }, default = "Bulmy",
	})
	maps:input({ text = "Custom place id", flag = "farm_custom", placeholder = "id" })

	local loop = group:section("Loop", false)
	loop:toggle({ text = "Collect loop", flag = "farm_collect" })
	loop:toggle({ text = "Open chests", flag = "farm_chests" })
	loop:toggle({ text = "Sell duplicate units", flag = "farm_sell_dupes" })
	loop:slider({
		text = "Loop delay (s)", flag = "farm_delay",
		min = 0.5, max = 10, step = 0.5, default = 2,
	})

	local report = group:section("Report", false)
	report:button({
		text = "Session summary",
		callback = function()
			print("[op3n] units:", #Data.units, "mine:", #Data.myUnits(),
				"currency:", Data.currency, "runs:", AutoPlay.runs)
		end,
	})
end)

-- ---------------- Hotbar ----------------

tab("Hotbar", function(group)
	local scan = group:section("Scan", false)
	scan:button({
		text = "Scan hotbar",
		callback = function()
			local slots = Data.scanHotbar()
			if #slots == 0 then
				print("[op3n] no slots found")
				return
			end
			for _, slot in ipairs(slots) do
				print(string.format("  [%d] lvl:%s cost:%s",
					slot.index, tostring(slot.level), tostring(slot.cost)))
			end
		end,
	})
	scan:button({
		text = "Scan currency",
		callback = function() print("[op3n] currency:", Data.scanCurrency()) end,
	})

	local auto = group:section("Auto buy", false)
	auto:toggle({ text = "Buy affordable slot", flag = "hotbar_buy" })
	auto:dropdown({
		text = "Preference", flag = "hotbar_pref",
		options = { "Cheapest", "Strongest", "In order", "Random" }, default = "Cheapest",
	})
end)

-- ---------------- Webhook ----------------

tab("Webhook", function(group)
	local endpoint = group:section("Endpoint", false)
	endpoint:input({
		text = "Webhook URL", flag = "webhook_url",
		placeholder = "https://discord.com/api/webhooks/...",
		callback = function(value) Webhook.url = value end,
	})
	endpoint:toggle({ text = "Send match results", flag = "webhook_match", default = true })
	endpoint:toggle({ text = "Send rare drops", flag = "webhook_rare", default = false })
	endpoint:button({
		text = "Send test",
		callback = function()
			Webhook.push("Test", "hello from op3n")
			Webhook.flush("Connection test")
		end,
	})
end)

-- ---------------- Settings ----------------

tab("Settings", function(group)
	local config = group:section("Config", false)
	config:button({
		text = "Save now",
		callback = function()
			Config.save()
			Hub.status("saved", Theme.good)
		end,
	})
	config:button({
		text = "Reset config",
		callback = function()
			Config.data = {}
			Config.save()
			Hub.status("reset - repaste hub", Theme.bad)
		end,
	})

	local help = group:section("Help", false)
	help:label({ text = "RightControl toggles the window." })
	help:label({ text = "Bridge needs one manual match to learn remote shapes." })
	help:label({ text = "Placement needs both anchors set." })
	help:label({ text = "Cards need auto pick enabled to fire." })
end)

-- ============================================================
-- loops
-- ============================================================

searchBox:GetPropertyChangedSignal("Text"):Connect(function()
	local query = searchBox.Text
	for _, entry in ipairs(Hub.tabs) do
		if entry.active then
			for _, section in ipairs(entry.group.sections) do
				Section.filter(section, query)
			end
		end
	end
end)

task.spawn(function()
	while alive() do
		task.wait(2)
		pcall(Data.refreshUnits)
	end
end)

task.spawn(function()
	while alive() do
		task.wait(0.5)
		pcall(AutoPlay.tick)
	end
end)

task.spawn(function()
	while alive() do
		task.wait(5)
		if Data.phaseGuess() == "match" then
			pcall(Data.scanHotbar)
			pcall(Data.scanCurrency)
		end
	end
end)

-- ============================================================
-- boot
-- ============================================================

do
	Cards.mode = Config.get("cards_mode", "Balanced")
	Cards.maxCurses = Config.get("cards_max_curses", 4)
	Cards.fromWave = Config.get("cards_from", 13)
	Cards.untilWave = Config.get("cards_until", 20)
	AutoPlay.limitRuns = Config.get("auto_limit_runs", 0)
	AutoPlay.limitMinutes = Config.get("auto_limit_minutes", 0)
	Webhook.url = Config.get("webhook_url", "")

	Hub.Config = Config
	Hub.Data = Data
	Hub.R = R
	Hub.Bridge = Bridge
	Hub.Placement = Placement
	Hub.Cards = Cards
	Hub.AutoPlay = AutoPlay
	Hub.Webhook = Webhook
	Hub.generation = Generation

	getgenv().Op3nHub = Hub

	if #Hub.tabs > 0 then Hub.selectTab(Hub.tabs[1].name) end
end

pcall(function()
	StarterGui:SetCore("SendNotification", {
		Title = "Op3n hub",
		Text = "RightControl to show / hide",
		Duration = 4,
	})
end)

print("[op3n] hub loaded - " .. #Hub.tabs .. " tabs - "
	.. tostring(R.c2s and "remotes ok" or "remotes missing")
	.. " - bridge " .. tostring(hookmetamethod and "learning" or "manual"))
