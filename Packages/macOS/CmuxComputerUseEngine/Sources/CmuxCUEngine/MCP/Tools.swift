// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The MCP tool surface: the ten Codex Computer Use tools, same names and
/// arguments, so an agent prompt written for one works on the other.
enum ToolCatalog {
    static func schema(_ properties: [String: Any], required: [String]) -> [String: Any] {
        ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
    }

    static let app: [String: Any] = ["type": "string", "description": "App name, bundle id or path (as list_apps prints it)."]
    static let index: [String: Any] = ["type": "integer", "description": "Element index from the app's latest state."]

    static let tools: [[String: Any]] = [
        ["name": "list_apps", "description": "List running apps.",
         "inputSchema": schema([:], required: []), "annotations": ["readOnlyHint": true]],
        ["name": "get_app_state",
         "description": "The app's key window as an indexed accessibility tree plus a screenshot. Indexes stay valid until the next state of that app; every action also returns the new state.",
         "inputSchema": schema(["app": app, "screenshot": ["type": "boolean", "description": "Default true."]], required: ["app"]),
         "annotations": ["readOnlyHint": true]],
        ["name": "click",
         "description": "Click an element (element_index) or a point (x, y in the latest screenshot's pixels). Returns the new state.",
         "inputSchema": schema(["app": app, "element_index": index,
                                "x": ["type": "number"], "y": ["type": "number"],
                                "mouse_button": ["type": "string", "enum": ["left", "right", "middle"]],
                                "click_count": ["type": "integer"]], required: ["app"])],
        ["name": "type_text", "description": "Type text into the app's focused element. Returns the new state.",
         "inputSchema": schema(["app": app, "text": ["type": "string"]], required: ["app", "text"])],
        ["name": "press_key",
         "description": "Press a key or chord in xdotool syntax (Return, Tab, super+c, ctrl+shift+Tab, KP_0). Returns the new state.",
         "inputSchema": schema(["app": app, "key": ["type": "string"]], required: ["app", "key"])],
        ["name": "scroll", "description": "Scroll an element (or the window) by pages. Returns the new state.",
         "inputSchema": schema(["app": app, "element_index": index,
                                "direction": ["type": "string", "enum": ["up", "down", "left", "right"]],
                                "pages": ["type": "number"]], required: ["app", "direction"])],
        ["name": "drag", "description": "Drag between two points in the latest screenshot's pixels. Returns the new state.",
         "inputSchema": schema(["app": app, "from_x": ["type": "number"], "from_y": ["type": "number"],
                                "to_x": ["type": "number"], "to_y": ["type": "number"]],
                               required: ["app", "from_x", "from_y", "to_x", "to_y"])],
        ["name": "set_value", "description": "Set a settable element's value. Returns the new state.",
         "inputSchema": schema(["app": app, "element_index": index, "value": ["type": "string"]],
                               required: ["app", "element_index", "value"])],
        ["name": "select_text", "description": "Select text inside a text element. Returns the new state.",
         "inputSchema": schema(["app": app, "element_index": index, "text": ["type": "string"]],
                               required: ["app", "element_index", "text"])],
        ["name": "perform_secondary_action",
         "description": "Perform one of an element's Secondary Actions (as its state line lists them). Returns the new state.",
         "inputSchema": schema(["app": app, "element_index": index, "action": ["type": "string"]],
                               required: ["app", "element_index", "action"])],
    ]
}

extension Engine {
    /// Runs one MCP tool call.
    func call(_ name: String, _ args: [String: Any]) async -> ToolResult {
        do {
            func string(_ key: String) throws -> String {
                guard let value = args[key] as? String, !value.isEmpty else { throw EngineError("\(key) is required") }
                return value
            }
            func int(_ key: String) -> Int? {
                if let value = args[key] as? NSNumber { return value.intValue }
                if let value = args[key] as? String { return Int(value) }
                return nil
            }
            func double(_ key: String) -> Double? {
                if let value = args[key] as? NSNumber { return value.doubleValue }
                if let value = args[key] as? String { return Double(value) }
                return nil
            }
            func required(_ key: String) throws -> Int {
                guard let value = int(key) else { throw EngineError("\(key) is required") }
                return value
            }
            switch name {
            case "list_apps":
                return listApps()
            case "get_app_state":
                return try await state(app: string("app"), screenshot: (args["screenshot"] as? Bool) ?? true)
            case "click":
                let button = PointerButton(rawValue: (args["mouse_button"] as? String) ?? "left") ?? .left
                return try await click(app: string("app"), index: int("element_index"), x: double("x"), y: double("y"),
                                       button: button, count: int("click_count") ?? 1)
            case "type_text":
                return try await typeText(app: string("app"), text: string("text"))
            case "press_key":
                return try await pressKey(app: string("app"), key: string("key"))
            case "scroll":
                return try await scroll(app: string("app"), index: int("element_index"), direction: string("direction"),
                                        pages: double("pages") ?? 1)
            case "drag":
                guard let fx = double("from_x"), let fy = double("from_y"), let tx = double("to_x"), let ty = double("to_y") else {
                    throw EngineError("drag needs from_x, from_y, to_x and to_y")
                }
                return try await drag(app: string("app"), from: (fx, fy), to: (tx, ty))
            case "set_value":
                return try await setValue(app: string("app"), index: required("element_index"), value: string("value"))
            case "select_text":
                return try await selectText(app: string("app"), index: required("element_index"), text: string("text"))
            case "perform_secondary_action":
                return try await secondaryAction(app: string("app"), index: required("element_index"), action: string("action"))
            default:
                return .error("unknown tool \(name)")
            }
        } catch {
            return .error("\(error)")
        }
    }
}
