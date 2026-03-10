// MCPToolRegistry.swift
// Tool registry and grouped tool implementations using direct socket RPC

import Foundation

// MARK: - MCPTool Protocol

/// Protocol that all MCP tools must implement
public protocol MCPExecutionTool {
    var name: String { get }
    var description: String { get }
    func execute(arguments: [String: Any]) throws -> MCPToolCallResult
    var inputSchema: MCPToolInputSchema { get }
}

// MARK: - Tool Registry

public final class MCPToolRegistry {

    private var tools: [String: MCPExecutionTool] = [:]
    private let backend: MCPBackend

    public init(backend: MCPBackend) {
        self.backend = backend
        registerDefaultTools()
    }

    public func register(_ tool: MCPExecutionTool) {
        tools[tool.name] = tool
    }

    public func listTools() -> [MCPExecutionTool] {
        Array(tools.values).sorted { $0.name < $1.name }
    }

    public func listToolDefinitions() -> [MCPToolDefinition] {
        listTools().map { MCPToolDefinition(name: $0.name, description: $0.description, inputSchema: $0.inputSchema) }
    }

    public func getTool(name: String) -> MCPExecutionTool? {
        tools[name]
    }

    public func executeTool(name: String, arguments: [String: Any]) throws -> MCPToolCallResult {
        guard let tool = tools[name] else { throw MCPError.toolNotFound(name) }
        return try tool.execute(arguments: arguments)
    }

    private func registerDefaultTools() {
        register(SystemTool(backend: backend))
        register(WorkspaceTool(backend: backend))
        register(WindowTool(backend: backend))
        register(PaneTool(backend: backend))
        register(SurfaceTool(backend: backend))
        register(NotificationTool(backend: backend))
        register(TabTool(backend: backend))
        register(BrowserTool(backend: backend))
    }
}

// MARK: - Action Definition & Grouped Tool Base

/// Defines validation rules for a single action within a grouped tool.
struct ActionDef {
    let required: [String]
    let optional: [String]
    /// Socket read timeout in milliseconds for this action. Long-running actions
    /// (e.g. browser.wait, download.wait) should use a larger value.
    let timeoutMs: Int32

    init(required: [String] = [], optional: [String] = [], timeoutMs: Int32 = 120_000) {
        self.required = required
        self.optional = optional
        self.timeoutMs = timeoutMs
    }
}

/// Base class for grouped MCP tools that map actions to socket RPC methods.
public class GroupedTool: MCPExecutionTool {
    public let name: String
    public let description: String
    public let inputSchema: MCPToolInputSchema
    let backend: MCPBackend
    let namespace: String
    let actions: [String: ActionDef]

    init(name: String, namespace: String, description: String, actions: [String: ActionDef], backend: MCPBackend) {
        self.name = name
        self.namespace = namespace
        self.description = description
        self.actions = actions
        self.backend = backend
        self.inputSchema = MCPToolInputSchema(
            properties: [
                "action": MCPToolProperty(type: "string", description: "The action to perform. See tool description for available actions.")
            ],
            required: ["action"]
        )
    }

    public func execute(arguments: [String: Any]) throws -> MCPToolCallResult {
        guard let action = arguments["action"] as? String else {
            throw MCPError.invalidParameters("Missing required parameter: action")
        }

        guard let def = actions[action] else {
            let available = actions.keys.sorted().joined(separator: ", ")
            throw MCPError.invalidParameters("Unknown action '\(action)'. Available: \(available)")
        }

        // Validate required params
        for param in def.required {
            guard arguments[param] != nil else {
                throw MCPError.invalidParameters("Action '\(action)' requires parameter: \(param)")
            }
        }

        // Build params dict (everything except "action")
        var params: [String: Any] = [:]
        let allowed = Set(def.required + def.optional)
        for (key, value) in arguments where key != "action" {
            if allowed.contains(key) {
                params[key] = value
            }
        }

        // Remap action_name -> action for *.action RPC methods
        // The socket handler expects params.action, but we use action_name in MCP
        // to avoid collision with the top-level action dispatch key.
        if action == "action", let actionName = params.removeValue(forKey: "action_name") {
            params["action"] = actionName
        }

        let method = "\(namespace).\(action)"
        return try backend.rpcForTool(method: method, params: params, timeoutMs: def.timeoutMs)
    }
}

// MARK: - System Tool

public final class SystemTool: GroupedTool {
    public init(backend: MCPBackend) {
        super.init(
            name: "cmux_system",
            namespace: "system",
            description: """
                System utility commands for cmux.

                Actions:
                - ping: Check if cmux is running. Params: (none)
                - identify: Get focused window/workspace/pane/surface context. Params: workspace (optional), surface (optional), no_caller (optional bool)
                - capabilities: List available socket methods and access mode. Params: (none)
                """,
            actions: [
                "ping": ActionDef(),
                "identify": ActionDef(optional: ["workspace", "surface", "no_caller"]),
                "capabilities": ActionDef(),
            ],
            backend: backend
        )
    }
}

// MARK: - Workspace Tool

public final class WorkspaceTool: GroupedTool {
    public init(backend: MCPBackend) {
        super.init(
            name: "cmux_workspace",
            namespace: "workspace",
            description: """
                Manage cmux workspaces (tabs in the tab bar).

                Actions:
                - list: List all workspaces. Params: (none)
                - create: Create a new workspace. Params: command (optional)
                - select: Switch to a workspace. Params: workspace_id (required)
                - close: Close a workspace. Params: workspace_id (required)
                - current: Get the active workspace. Params: (none)
                - rename: Rename a workspace. Params: workspace_id (required), name (required)
                - next: Switch to next workspace. Params: (none)
                - previous: Switch to previous workspace. Params: (none)
                - last: Switch to last active workspace. Params: (none)
                - reorder: Reorder a workspace. Params: workspace_id (required), index (required)
                - action: Run a workspace action. Params: workspace_id (required), action_name (required)
                - move_to_window: Move workspace to another window. Params: workspace_id (required), window_id (optional)
                """,
            actions: [
                "list": ActionDef(),
                "create": ActionDef(optional: ["command", "cwd"]),
                "select": ActionDef(required: ["workspace_id"]),
                "close": ActionDef(required: ["workspace_id"]),
                "current": ActionDef(),
                "rename": ActionDef(required: ["workspace_id", "name"]),
                "next": ActionDef(),
                "previous": ActionDef(),
                "last": ActionDef(),
                "reorder": ActionDef(required: ["workspace_id", "index"]),
                "action": ActionDef(required: ["workspace_id", "action_name"]),
                "move_to_window": ActionDef(required: ["workspace_id"], optional: ["window_id"]),
            ],
            backend: backend
        )
    }
}

// MARK: - Window Tool

public final class WindowTool: GroupedTool {
    public init(backend: MCPBackend) {
        super.init(
            name: "cmux_window",
            namespace: "window",
            description: """
                Manage cmux windows.

                Actions:
                - list: List all windows. Params: (none)
                - create: Create a new window. Params: (none)
                - close: Close a window. Params: window_id (required)
                - focus: Focus a window. Params: window_id (required)
                - current: Get the active window. Params: (none)
                """,
            actions: [
                "list": ActionDef(),
                "create": ActionDef(),
                "close": ActionDef(required: ["window_id"]),
                "focus": ActionDef(required: ["window_id"]),
                "current": ActionDef(),
            ],
            backend: backend
        )
    }
}

// MARK: - Pane Tool

public final class PaneTool: GroupedTool {
    public init(backend: MCPBackend) {
        super.init(
            name: "cmux_pane",
            namespace: "pane",
            description: """
                Manage panes (split containers) within a workspace.

                Actions:
                - list: List all panes in a workspace. Params: workspace_id (optional)
                - surfaces: List surfaces in a pane. Params: pane_id (optional)
                - focus: Focus a pane. Params: pane_id (required)
                - create: Create a new pane. Params: direction (required: left/right/up/down), pane_id (optional)
                - resize: Resize a pane. Params: pane_id (required), amount (required)
                - swap: Swap two panes. Params: pane_id (required), target_pane_id (required)
                - break: Break pane into its own workspace. Params: pane_id (required)
                - join: Join a pane into another. Params: pane_id (required), target_pane_id (required), direction (required)
                - last: Focus the last active pane. Params: (none)
                """,
            actions: [
                "list": ActionDef(optional: ["workspace_id"]),
                "surfaces": ActionDef(optional: ["pane_id"]),
                "focus": ActionDef(required: ["pane_id"]),
                "create": ActionDef(required: ["direction"], optional: ["pane_id"]),
                "resize": ActionDef(required: ["pane_id", "amount"]),
                "swap": ActionDef(required: ["pane_id", "target_pane_id"]),
                "break": ActionDef(required: ["pane_id"]),
                "join": ActionDef(required: ["pane_id", "target_pane_id", "direction"]),
                "last": ActionDef(),
            ],
            backend: backend
        )
    }
}

// MARK: - Surface Tool

public final class SurfaceTool: GroupedTool {
    public init(backend: MCPBackend) {
        super.init(
            name: "cmux_surface",
            namespace: "surface",
            description: """
                Interact with terminal surfaces (individual terminal instances).

                Actions:
                - list: List all surfaces. Params: workspace_id (optional)
                - focus: Focus a surface. Params: surface_id (required)
                - read_text: Read terminal screen text. Params: surface_id (optional), scrollback (optional bool), lines (optional number)
                - send_text: Send text input to a surface. Params: text (required), surface_id (optional)
                - send_key: Send a key press. Params: key (required, e.g. 'enter', 'ctrl-c', 'escape', 'tab', 'up', 'down'), surface_id (optional)
                - split: Create a new split. Params: direction (required: left/right/up/down), surface_id (optional)
                - close: Close a surface. Params: surface_id (required)
                - create: Create a new surface. Params: (none)
                - current: Get the focused surface. Params: (none)
                - move: Move a surface. Params: surface_id (required), target_pane_id (required)
                - reorder: Reorder surface within pane. Params: surface_id (required), index (required)
                - trigger_flash: Flash a surface for attention. Params: surface_id (optional)
                - clear_history: Clear scrollback history. Params: surface_id (optional)
                - health: Check surface health. Params: surface_id (optional)
                - action: Run a surface action. Params: surface_id (required), action_name (required)
                - refresh: Refresh a surface. Params: surface_id (optional)
                - drag_to_split: Drag surface to create split. Params: surface_id (required), direction (required)
                """,
            actions: [
                "list": ActionDef(optional: ["workspace_id"]),
                "focus": ActionDef(required: ["surface_id"]),
                "read_text": ActionDef(optional: ["surface_id", "scrollback", "lines"]),
                "send_text": ActionDef(required: ["text"], optional: ["surface_id"]),
                "send_key": ActionDef(required: ["key"], optional: ["surface_id"]),
                "split": ActionDef(required: ["direction"], optional: ["surface_id"]),
                "close": ActionDef(required: ["surface_id"]),
                "create": ActionDef(),
                "current": ActionDef(),
                "move": ActionDef(required: ["surface_id", "target_pane_id"]),
                "reorder": ActionDef(required: ["surface_id", "index"]),
                "trigger_flash": ActionDef(optional: ["surface_id"]),
                "clear_history": ActionDef(optional: ["surface_id"]),
                "health": ActionDef(optional: ["surface_id"]),
                "action": ActionDef(required: ["surface_id", "action_name"]),
                "refresh": ActionDef(optional: ["surface_id"]),
                "drag_to_split": ActionDef(required: ["surface_id", "direction"]),
            ],
            backend: backend
        )
    }

    /// Override to extract just the text field from read_text responses.
    public override func execute(arguments: [String: Any]) throws -> MCPToolCallResult {
        guard let action = arguments["action"] as? String else {
            throw MCPError.invalidParameters("Missing required parameter: action")
        }

        // For read_text, return just the text content for cleaner output
        if action == "read_text" {
            guard let def = actions[action] else {
                throw MCPError.invalidParameters("Unknown action '\(action)'")
            }
            for param in def.required {
                guard arguments[param] != nil else {
                    throw MCPError.invalidParameters("Action '\(action)' requires parameter: \(param)")
                }
            }
            var params: [String: Any] = [:]
            let allowed = Set(def.required + def.optional)
            for (key, value) in arguments where key != "action" {
                if allowed.contains(key) { params[key] = value }
            }
            let result = try backend.rpc(method: "surface.read_text", params: params)
            if let text = result["text"] as? String {
                return MCPToolCallResult(content: [.text(text)])
            }
            let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
            let text = String(data: data, encoding: .utf8) ?? "{}"
            return MCPToolCallResult(content: [.text(text)])
        }

        return try super.execute(arguments: arguments)
    }
}

// MARK: - Notification Tool

public final class NotificationTool: GroupedTool {
    public init(backend: MCPBackend) {
        super.init(
            name: "cmux_notification",
            namespace: "notification",
            description: """
                Manage cmux notifications.

                Actions:
                - create: Send a notification. Params: title (required), body (optional), subtitle (optional)
                - create_for_surface: Notify for a surface. Params: surface_id (required), title (required), body (optional)
                - create_for_target: Notify for a target. Params: target (required), title (required), body (optional)
                - list: List all notifications. Params: (none)
                - clear: Clear all notifications. Params: (none)
                """,
            actions: [
                "create": ActionDef(required: ["title"], optional: ["body", "subtitle"]),
                "create_for_surface": ActionDef(required: ["surface_id", "title"], optional: ["body"]),
                "create_for_target": ActionDef(required: ["target", "title"], optional: ["body"]),
                "list": ActionDef(),
                "clear": ActionDef(),
            ],
            backend: backend
        )
    }
}

// MARK: - Tab Tool

public final class TabTool: GroupedTool {
    public init(backend: MCPBackend) {
        super.init(
            name: "cmux_tab",
            namespace: "tab",
            description: """
                Tab actions.

                Actions:
                - action: Run a tab action. Params: tab_id (required), action_name (required)
                """,
            actions: [
                "action": ActionDef(required: ["tab_id", "action_name"]),
            ],
            backend: backend
        )
    }
}

// MARK: - Browser Tool

public final class BrowserTool: GroupedTool {
    public init(backend: MCPBackend) {
        super.init(
            name: "cmux_browser",
            namespace: "browser",
            description: """
                Browser automation for cmux web views. All actions target the focused browser surface unless surface_id is provided.

                Navigation:
                - navigate: Go to URL. Params: url (required), surface_id (optional)
                - back: Go back. Params: surface_id (optional)
                - forward: Go forward. Params: surface_id (optional)
                - reload: Reload page. Params: surface_id (optional)

                Finding elements:
                - find.text: Find by text. Params: text (required), surface_id (optional)
                - find.role: Find by ARIA role. Params: role (required), name (optional), surface_id (optional)
                - find.label: Find by label. Params: label (required), surface_id (optional)
                - find.placeholder: Find by placeholder. Params: placeholder (required), surface_id (optional)
                - find.testid: Find by test ID. Params: testid (required), surface_id (optional)
                - find.alt: Find by alt text. Params: alt (required), surface_id (optional)
                - find.title: Find by title. Params: title (required), surface_id (optional)
                - find.first: Find first element. Params: selector (required), surface_id (optional)
                - find.last: Find last element. Params: selector (required), surface_id (optional)
                - find.nth: Find nth element. Params: selector (required), index (required), surface_id (optional)

                Interaction:
                - click: Click element. Params: selector (required), surface_id (optional)
                - dblclick: Double-click. Params: selector (required), surface_id (optional)
                - hover: Hover element. Params: selector (required), surface_id (optional)
                - fill: Fill input. Params: selector (required), value (required), surface_id (optional)
                - type: Type text. Params: selector (required), text (required), surface_id (optional)
                - press: Press key. Params: key (required), surface_id (optional)
                - check: Check checkbox. Params: selector (required), surface_id (optional)
                - uncheck: Uncheck checkbox. Params: selector (required), surface_id (optional)
                - select: Select option. Params: selector (required), value (required), surface_id (optional)
                - focus: Focus element. Params: selector (required), surface_id (optional)
                - scroll: Scroll. Params: selector (optional), x (optional), y (optional), surface_id (optional)
                - scroll_into_view: Scroll element into view. Params: selector (required), surface_id (optional)

                Inspection:
                - get.text: Get text content. Params: selector (required), surface_id (optional)
                - get.html: Get HTML. Params: selector (required), surface_id (optional)
                - get.attr: Get attribute. Params: selector (required), attribute (required), surface_id (optional)
                - get.value: Get input value. Params: selector (required), surface_id (optional)
                - get.title: Get page title. Params: surface_id (optional)
                - get.box: Get bounding box. Params: selector (required), surface_id (optional)
                - get.count: Count elements. Params: selector (required), surface_id (optional)
                - get.styles: Get computed styles. Params: selector (required), properties (optional), surface_id (optional)
                - url.get: Get current URL. Params: surface_id (optional)
                - is.visible: Check visibility. Params: selector (required), surface_id (optional)
                - is.enabled: Check enabled. Params: selector (required), surface_id (optional)
                - is.checked: Check checked. Params: selector (required), surface_id (optional)

                Page:
                - screenshot: Take screenshot. Params: selector (optional), path (optional), surface_id (optional)
                - snapshot: Get accessibility snapshot. Params: surface_id (optional)
                - eval: Evaluate JavaScript. Params: expression (required), surface_id (optional)
                - wait: Wait for condition. Params: selector (optional), state (optional), timeout (optional), surface_id (optional)
                - highlight: Highlight element. Params: selector (required), surface_id (optional)

                Tabs:
                - tab.new: Open new tab. Params: url (optional), surface_id (optional)
                - tab.list: List tabs. Params: surface_id (optional)
                - tab.switch: Switch tab. Params: index (required), surface_id (optional)
                - tab.close: Close tab. Params: index (optional), surface_id (optional)

                Advanced:
                - cookies.get: Get cookies. Params: url (optional), surface_id (optional)
                - cookies.set: Set cookie. Params: name (required), value (required), domain (optional), surface_id (optional)
                - cookies.clear: Clear cookies. Params: surface_id (optional)
                - storage.get: Get storage. Params: key (required), type (optional), surface_id (optional)
                - storage.set: Set storage. Params: key (required), value (required), type (optional), surface_id (optional)
                - storage.clear: Clear storage. Params: type (optional), surface_id (optional)
                - console.list: List console messages. Params: surface_id (optional)
                - console.clear: Clear console. Params: surface_id (optional)
                - errors.list: List page errors. Params: surface_id (optional)
                - network.requests: List network requests. Params: surface_id (optional)
                - network.route: Set up network route. Params: pattern (required), response (optional), surface_id (optional)
                - network.unroute: Remove network route. Params: pattern (required), surface_id (optional)
                - viewport.set: Set viewport size. Params: width (required), height (required), surface_id (optional)
                - geolocation.set: Set geolocation. Params: latitude (required), longitude (required), surface_id (optional)
                - offline.set: Toggle offline mode. Params: offline (required), surface_id (optional)

                Scripts & Styles:
                - addscript: Add script. Params: content (optional), url (optional), surface_id (optional)
                - addinitscript: Add init script. Params: script (required), surface_id (optional)
                - addstyle: Add stylesheet. Params: content (optional), url (optional), surface_id (optional)

                Input:
                - input_keyboard: Raw keyboard input. Params: type (required), key (required), surface_id (optional)
                - input_mouse: Raw mouse input. Params: type (required), x (required), y (required), button (optional), surface_id (optional)
                - input_touch: Raw touch input. Params: type (required), x (required), y (required), surface_id (optional)
                - keydown: Key down. Params: key (required), surface_id (optional)
                - keyup: Key up. Params: key (required), surface_id (optional)

                State:
                - state.save: Save browser state. Params: name (required), surface_id (optional)
                - state.load: Load browser state. Params: name (required), surface_id (optional)

                Frames:
                - frame.main: Switch to main frame. Params: surface_id (optional)
                - frame.select: Switch to frame. Params: selector (required), surface_id (optional)

                Recording:
                - screencast.start: Start screencast. Params: path (optional), surface_id (optional)
                - screencast.stop: Stop screencast. Params: surface_id (optional)
                - trace.start: Start trace. Params: path (optional), surface_id (optional)
                - trace.stop: Stop trace. Params: surface_id (optional)
                - download.wait: Wait for download. Params: surface_id (optional)

                Other:
                - dialog.accept: Accept dialog. Params: text (optional), surface_id (optional)
                - dialog.dismiss: Dismiss dialog. Params: surface_id (optional)
                - open_split: Open browser in split. Params: url (optional), direction (optional), surface_id (optional)
                - focus_webview: Focus the web view. Params: surface_id (optional)
                - is_webview_focused: Check if web view is focused. Params: surface_id (optional)
                """,
            actions: [
                // Navigation
                "navigate": ActionDef(required: ["url"], optional: ["surface_id"]),
                "back": ActionDef(optional: ["surface_id"]),
                "forward": ActionDef(optional: ["surface_id"]),
                "reload": ActionDef(optional: ["surface_id"]),
                // Finding elements
                "find.text": ActionDef(required: ["text"], optional: ["surface_id"]),
                "find.role": ActionDef(required: ["role"], optional: ["name", "surface_id"]),
                "find.label": ActionDef(required: ["label"], optional: ["surface_id"]),
                "find.placeholder": ActionDef(required: ["placeholder"], optional: ["surface_id"]),
                "find.testid": ActionDef(required: ["testid"], optional: ["surface_id"]),
                "find.alt": ActionDef(required: ["alt"], optional: ["surface_id"]),
                "find.title": ActionDef(required: ["title"], optional: ["surface_id"]),
                "find.first": ActionDef(required: ["selector"], optional: ["surface_id"]),
                "find.last": ActionDef(required: ["selector"], optional: ["surface_id"]),
                "find.nth": ActionDef(required: ["selector", "index"], optional: ["surface_id"]),
                // Interaction
                "click": ActionDef(required: ["selector"], optional: ["surface_id"]),
                "dblclick": ActionDef(required: ["selector"], optional: ["surface_id"]),
                "hover": ActionDef(required: ["selector"], optional: ["surface_id"]),
                "fill": ActionDef(required: ["selector", "value"], optional: ["surface_id"]),
                "type": ActionDef(required: ["selector", "text"], optional: ["surface_id"]),
                "press": ActionDef(required: ["key"], optional: ["surface_id"]),
                "check": ActionDef(required: ["selector"], optional: ["surface_id"]),
                "uncheck": ActionDef(required: ["selector"], optional: ["surface_id"]),
                "select": ActionDef(required: ["selector", "value"], optional: ["surface_id"]),
                "focus": ActionDef(required: ["selector"], optional: ["surface_id"]),
                "scroll": ActionDef(optional: ["selector", "x", "y", "surface_id"]),
                "scroll_into_view": ActionDef(required: ["selector"], optional: ["surface_id"]),
                // Inspection
                "get.text": ActionDef(required: ["selector"], optional: ["surface_id"]),
                "get.html": ActionDef(required: ["selector"], optional: ["surface_id"]),
                "get.attr": ActionDef(required: ["selector", "attribute"], optional: ["surface_id"]),
                "get.value": ActionDef(required: ["selector"], optional: ["surface_id"]),
                "get.title": ActionDef(optional: ["surface_id"]),
                "get.box": ActionDef(required: ["selector"], optional: ["surface_id"]),
                "get.count": ActionDef(required: ["selector"], optional: ["surface_id"]),
                "get.styles": ActionDef(required: ["selector"], optional: ["properties", "surface_id"]),
                "url.get": ActionDef(optional: ["surface_id"]),
                "is.visible": ActionDef(required: ["selector"], optional: ["surface_id"]),
                "is.enabled": ActionDef(required: ["selector"], optional: ["surface_id"]),
                "is.checked": ActionDef(required: ["selector"], optional: ["surface_id"]),
                // Page
                "screenshot": ActionDef(optional: ["selector", "path", "surface_id"]),
                "snapshot": ActionDef(optional: ["surface_id"]),
                "eval": ActionDef(required: ["expression"], optional: ["surface_id"]),
                "wait": ActionDef(optional: ["selector", "state", "timeout", "surface_id"], timeoutMs: 300_000),
                "highlight": ActionDef(required: ["selector"], optional: ["surface_id"]),
                // Tabs
                "tab.new": ActionDef(optional: ["url", "surface_id"]),
                "tab.list": ActionDef(optional: ["surface_id"]),
                "tab.switch": ActionDef(required: ["index"], optional: ["surface_id"]),
                "tab.close": ActionDef(optional: ["index", "surface_id"]),
                // Cookies
                "cookies.get": ActionDef(optional: ["url", "surface_id"]),
                "cookies.set": ActionDef(required: ["name", "value"], optional: ["domain", "surface_id"]),
                "cookies.clear": ActionDef(optional: ["surface_id"]),
                // Storage
                "storage.get": ActionDef(required: ["key"], optional: ["type", "surface_id"]),
                "storage.set": ActionDef(required: ["key", "value"], optional: ["type", "surface_id"]),
                "storage.clear": ActionDef(optional: ["type", "surface_id"]),
                // Console & errors
                "console.list": ActionDef(optional: ["surface_id"]),
                "console.clear": ActionDef(optional: ["surface_id"]),
                "errors.list": ActionDef(optional: ["surface_id"]),
                // Network
                "network.requests": ActionDef(optional: ["surface_id"]),
                "network.route": ActionDef(required: ["pattern"], optional: ["response", "surface_id"]),
                "network.unroute": ActionDef(required: ["pattern"], optional: ["surface_id"]),
                // Viewport & environment
                "viewport.set": ActionDef(required: ["width", "height"], optional: ["surface_id"]),
                "geolocation.set": ActionDef(required: ["latitude", "longitude"], optional: ["surface_id"]),
                "offline.set": ActionDef(required: ["offline"], optional: ["surface_id"]),
                // Scripts & styles
                "addscript": ActionDef(optional: ["content", "url", "surface_id"]),
                "addinitscript": ActionDef(required: ["script"], optional: ["surface_id"]),
                "addstyle": ActionDef(optional: ["content", "url", "surface_id"]),
                // Raw input
                "input_keyboard": ActionDef(required: ["type", "key"], optional: ["surface_id"]),
                "input_mouse": ActionDef(required: ["type", "x", "y"], optional: ["button", "surface_id"]),
                "input_touch": ActionDef(required: ["type", "x", "y"], optional: ["surface_id"]),
                "keydown": ActionDef(required: ["key"], optional: ["surface_id"]),
                "keyup": ActionDef(required: ["key"], optional: ["surface_id"]),
                // State
                "state.save": ActionDef(required: ["name"], optional: ["surface_id"]),
                "state.load": ActionDef(required: ["name"], optional: ["surface_id"]),
                // Frames
                "frame.main": ActionDef(optional: ["surface_id"]),
                "frame.select": ActionDef(required: ["selector"], optional: ["surface_id"]),
                // Recording
                "screencast.start": ActionDef(optional: ["path", "surface_id"]),
                "screencast.stop": ActionDef(optional: ["surface_id"]),
                "trace.start": ActionDef(optional: ["path", "surface_id"]),
                "trace.stop": ActionDef(optional: ["surface_id"]),
                "download.wait": ActionDef(optional: ["surface_id"], timeoutMs: 300_000),
                // Dialog
                "dialog.accept": ActionDef(optional: ["text", "surface_id"]),
                "dialog.dismiss": ActionDef(optional: ["surface_id"]),
                // Other
                "open_split": ActionDef(optional: ["url", "direction", "surface_id"]),
                "focus_webview": ActionDef(optional: ["surface_id"]),
                "is_webview_focused": ActionDef(optional: ["surface_id"]),
            ],
            backend: backend
        )
    }
}
