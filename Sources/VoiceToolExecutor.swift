import Foundation

struct VoiceToolExecutionResult {
    let payload: [String: Any]

    var displaySummary: String {
        if let ok = payload["ok"] as? Bool, !ok {
            return String(localized: "voice.tool.failed", defaultValue: "Failed")
        }
        return String(localized: "voice.tool.done", defaultValue: "Done")
    }

    var outputJSONString: String {
        (try? VoiceJSON.string(from: payload)) ?? "{\"ok\":false,\"message\":\"Failed to encode tool result.\"}"
    }
}

@MainActor
final class VoiceToolExecutor {
    private struct FocusTarget {
        let targetType: String
        let id: String
    }

    private var lastFocusTarget: FocusTarget?
    private var lastWindowID: String?
    private var lastWorkspaceID: String?
    private var lastPaneID: String?
    private var lastSurfaceID: String?

    var toolDefinitions: [[String: Any]] {
        [
            tool(
                name: "cmux_get_context",
                description: "Get the current cmux window, workspace, pane, and surface tree. Use this before choosing a target when the user is ambiguous.",
                properties: [:]
            ),
            tool(
                name: "cmux_read_terminal",
                description: "Read visible terminal text or recent scrollback from a terminal surface.",
                properties: commonTargetProperties().merging([
                    "lines": integerProperty("Maximum number of recent lines to read. Defaults to 80."),
                    "scrollback": booleanProperty("Include scrollback.")
                ]) { current, _ in current }
            ),
            tool(
                name: "cmux_create_workspace",
                description: "Create a new cmux workspace.",
                properties: [
                    "title": stringProperty("Optional workspace title."),
                    "working_directory": stringProperty("Optional working directory."),
                    "initial_command": stringProperty("Optional command to run in the initial terminal."),
                    "description": stringProperty("Optional workspace description."),
                    "focus": booleanProperty("Select and focus the new workspace. Defaults to true.")
                ]
            ),
            tool(
                name: "cmux_create_terminal",
                description: "Create a new terminal surface in the focused pane or a specified pane.",
                properties: commonTargetProperties().merging([
                    "pane_id": stringProperty("Optional pane UUID to receive the terminal.")
                ]) { current, _ in current }
            ),
            tool(
                name: "cmux_create_split",
                description: "Create a split pane with a terminal or browser.",
                properties: commonTargetProperties().merging([
                    "direction": [
                        "type": "string",
                        "description": "Split direction.",
                        "enum": ["left", "right", "up", "down"]
                    ],
                    "type": [
                        "type": "string",
                        "description": "Surface type for the new split.",
                        "enum": ["terminal", "browser"]
                    ],
                    "url": stringProperty("URL when creating a browser split.")
                ]) { current, _ in current },
                required: ["direction"]
            ),
            tool(
                name: "cmux_run_command",
                description: "Run a shell command in a terminal by sending text followed by Enter. Set confirmed true only when the user explicitly asked to run this exact command or confirmed it.",
                properties: commonTargetProperties().merging([
                    "command": stringProperty("The exact shell command to run."),
                    "confirmed": booleanProperty("True only when the user explicitly asked to run this command or confirmed it.")
                ]) { current, _ in current },
                required: ["command", "confirmed"]
            ),
            tool(
                name: "cmux_open_browser",
                description: "Open a browser split for a URL.",
                properties: commonTargetProperties().merging([
                    "url": stringProperty("The URL to open.")
                ]) { current, _ in current },
                required: ["url"]
            ),
            tool(
                name: "cmux_browser_snapshot",
                description: "Return a compact accessibility-like snapshot for a browser surface.",
                properties: commonTargetProperties().merging([
                    "surface_id": stringProperty("Browser surface UUID."),
                    "max_depth": integerProperty("Maximum DOM depth. Defaults to 8."),
                    "interactive": booleanProperty("Only include interactive nodes.")
                ]) { current, _ in current }
            ),
            tool(
                name: "cmux_browser_navigate",
                description: "Navigate a browser surface to a URL.",
                properties: commonTargetProperties().merging([
                    "surface_id": stringProperty("Browser surface UUID."),
                    "url": stringProperty("The URL to navigate to.")
                ]) { current, _ in current },
                required: ["url"]
            ),
            tool(
                name: "cmux_browser_click",
                description: "Click an element in a browser surface by selector or element ref from a snapshot.",
                properties: commonTargetProperties().merging([
                    "surface_id": stringProperty("Browser surface UUID."),
                    "selector": stringProperty("CSS selector or element ref, such as @e1.")
                ]) { current, _ in current },
                required: ["selector"]
            ),
            tool(
                name: "cmux_browser_type",
                description: "Type or fill text into a browser element.",
                properties: commonTargetProperties().merging([
                    "surface_id": stringProperty("Browser surface UUID."),
                    "selector": stringProperty("CSS selector or element ref, such as @e1."),
                    "text": stringProperty("Text to enter."),
                    "replace": booleanProperty("Replace existing value instead of typing into the element. Defaults to true.")
                ]) { current, _ in current },
                required: ["selector", "text"]
            ),
            tool(
                name: "cmux_focus",
                description: "Focus a cmux window, workspace, pane, or surface by UUID. If the id is omitted, focus the most recently created or referenced object.",
                properties: [
                    "target_type": [
                        "type": "string",
                        "description": "Object type to focus. Omit this to focus the most recently created or referenced object.",
                        "enum": ["window", "workspace", "pane", "surface"]
                    ],
                    "id": stringProperty("The UUID for the target. Omit this to focus the most recently created or referenced object of target_type.")
                ]
            )
        ]
    }

    func execute(name: String, argumentsJSON: String) async -> VoiceToolExecutionResult {
        let arguments = VoiceJSON.parseArguments(argumentsJSON)

        switch name {
        case "cmux_get_context":
            return getContext()
        case "cmux_read_terminal":
            var params = targetParams(from: arguments)
            params["lines"] = intValue(arguments["lines"]) ?? 80
            params["scrollback"] = boolValue(arguments["scrollback"]) ?? true
            return callV2(method: "surface.read_text", params: params)
        case "cmux_create_workspace":
            var params = selectedParams(arguments, keys: [
                "title",
                "working_directory",
                "initial_command",
                "description"
            ])
            params["focus"] = boolValue(arguments["focus"]) ?? true
            return callV2(method: "workspace.create", params: params)
        case "cmux_create_terminal":
            var params = targetParams(from: arguments)
            params["type"] = "terminal"
            if let paneID = stringValue(arguments["pane_id"]) {
                params["pane_id"] = paneID
            }
            return callV2(method: "surface.create", params: params)
        case "cmux_create_split":
            var params = targetParams(from: arguments)
            params["direction"] = stringValue(arguments["direction"]) ?? "right"
            params["type"] = stringValue(arguments["type"]) ?? "terminal"
            if let url = stringValue(arguments["url"]) {
                params["url"] = url
            }
            return callV2(method: "pane.create", params: params)
        case "cmux_run_command":
            let command = stringValue(arguments["command"]) ?? ""
            guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return failure(message: "Missing command.", code: "missing_command")
            }
            guard boolValue(arguments["confirmed"]) == true else {
                return VoiceToolExecutionResult(payload: [
                    "ok": false,
                    "requires_confirmation": true,
                    "command": command,
                    "message": "Ask the user to confirm before running this command."
                ])
            }
            var params = targetParams(from: arguments)
            params["text"] = command.hasSuffix("\n") ? command : "\(command)\n"
            return callV2(method: "surface.send_text", params: params)
        case "cmux_open_browser":
            guard let url = stringValue(arguments["url"]) else {
                return failure(message: "Missing URL.", code: "missing_url")
            }
            var params = targetParams(from: arguments)
            params["url"] = url
            return callV2(method: "browser.open_split", params: params)
        case "cmux_browser_snapshot":
            var params = targetParams(from: arguments)
            params["compact"] = true
            params["max_depth"] = intValue(arguments["max_depth"]) ?? 8
            params["interactive"] = boolValue(arguments["interactive"]) ?? false
            return callV2(method: "browser.snapshot", params: params)
        case "cmux_browser_navigate":
            guard let url = stringValue(arguments["url"]) else {
                return failure(message: "Missing URL.", code: "missing_url")
            }
            var params = targetParams(from: arguments)
            params["url"] = url
            return callV2(method: "browser.navigate", params: params)
        case "cmux_browser_click":
            guard let selector = stringValue(arguments["selector"]) else {
                return failure(message: "Missing selector.", code: "missing_selector")
            }
            var params = targetParams(from: arguments)
            params["selector"] = selector
            return callV2(method: "browser.click", params: params)
        case "cmux_browser_type":
            guard let selector = stringValue(arguments["selector"]),
                  let text = stringValue(arguments["text"]) else {
                return failure(message: "Missing selector or text.", code: "missing_browser_type_params")
            }
            var params = targetParams(from: arguments)
            params["selector"] = selector
            params["text"] = text
            let method = (boolValue(arguments["replace"]) ?? true) ? "browser.fill" : "browser.type"
            return callV2(method: method, params: params)
        case "cmux_focus":
            return focus(arguments: arguments)
        default:
            return failure(message: "Unknown voice tool: \(name)", code: "unknown_tool")
        }
    }

    private func getContext() -> VoiceToolExecutionResult {
        let identify = callV2(method: "system.identify", params: [:]).payload
        let tree = callV2(method: "system.tree", params: ["all_windows": true]).payload
        return VoiceToolExecutionResult(payload: [
            "ok": true,
            "identify": identify,
            "tree": tree
        ])
    }

    private func focus(arguments: [String: Any]) -> VoiceToolExecutionResult {
        guard let target = resolvedFocusTarget(from: arguments) else {
            return failure(message: "Missing focus target.", code: "missing_focus_target")
        }

        switch target.targetType {
        case "window":
            return callV2(method: "window.focus", params: ["window_id": target.id])
        case "workspace":
            return callV2(method: "workspace.select", params: ["workspace_id": target.id])
        case "pane":
            return callV2(method: "pane.focus", params: ["pane_id": target.id])
        case "surface":
            return callV2(method: "surface.focus", params: ["surface_id": target.id])
        default:
            return failure(message: "Unsupported focus target: \(target.targetType)", code: "unsupported_focus_target")
        }
    }

    private func resolvedFocusTarget(from arguments: [String: Any]) -> FocusTarget? {
        let requestedTargetType = stringValue(arguments["target_type"])
        let requestedID = stringValue(arguments["id"])

        if let requestedTargetType,
           let requestedID {
            return FocusTarget(targetType: requestedTargetType, id: requestedID)
        }

        if let requestedTargetType,
           let rememberedID = rememberedID(for: requestedTargetType) {
            return FocusTarget(targetType: requestedTargetType, id: rememberedID)
        }

        if let requestedID,
           let rememberedTargetType = rememberedTargetType(for: requestedID) ?? lastFocusTarget?.targetType {
            return FocusTarget(targetType: rememberedTargetType, id: requestedID)
        }

        return lastFocusTarget
    }

    private func rememberedTargetType(for id: String) -> String? {
        if lastWindowID == id {
            return "window"
        }
        if lastWorkspaceID == id {
            return "workspace"
        }
        if lastPaneID == id {
            return "pane"
        }
        if lastSurfaceID == id {
            return "surface"
        }
        return nil
    }

    private func rememberedID(for targetType: String) -> String? {
        switch targetType {
        case "window":
            return lastWindowID
        case "workspace":
            return lastWorkspaceID
        case "pane":
            return lastPaneID
        case "surface":
            return lastSurfaceID
        default:
            return nil
        }
    }

    private func callV2(method: String, params: [String: Any]) -> VoiceToolExecutionResult {
        let request: [String: Any] = [
            "id": UUID().uuidString,
            "method": method,
            "params": params
        ]

        do {
            let line = try VoiceJSON.string(from: request)
            let response = TerminalController.shared.handleSocketLine(line)
            guard let object = VoiceJSON.dictionary(fromJSONString: response) else {
                return failure(message: response, code: "invalid_rpc_response", method: method)
            }
            if object["ok"] as? Bool == true {
                let payload: [String: Any] = [
                    "ok": true,
                    "method": method,
                    "result": object["result"] ?? NSNull()
                ]
                rememberFocusTargets(from: payload)
                return VoiceToolExecutionResult(payload: payload)
            }
            return VoiceToolExecutionResult(payload: [
                "ok": false,
                "method": method,
                "error": object["error"] ?? object
            ])
        } catch {
            return failure(message: error.localizedDescription, code: "rpc_encoding_failed", method: method)
        }
    }

    private func rememberFocusTargets(from payload: [String: Any]) {
        let result = (payload["result"] as? [String: Any]) ?? payload
        if let windowID = stringValue(result["window_id"]) {
            lastWindowID = windowID
            lastFocusTarget = FocusTarget(targetType: "window", id: windowID)
        }
        if let workspaceID = stringValue(result["workspace_id"]) {
            lastWorkspaceID = workspaceID
            lastFocusTarget = FocusTarget(targetType: "workspace", id: workspaceID)
        }
        if let paneID = stringValue(result["pane_id"]) {
            lastPaneID = paneID
            lastFocusTarget = FocusTarget(targetType: "pane", id: paneID)
        }
        if let surfaceID = stringValue(result["surface_id"]) {
            lastSurfaceID = surfaceID
            lastFocusTarget = FocusTarget(targetType: "surface", id: surfaceID)
        }
    }

    private func failure(message: String, code: String, method: String? = nil) -> VoiceToolExecutionResult {
        var payload: [String: Any] = [
            "ok": false,
            "code": code,
            "message": message
        ]
        if let method {
            payload["method"] = method
        }
        return VoiceToolExecutionResult(payload: payload)
    }

    private func targetParams(from arguments: [String: Any]) -> [String: Any] {
        selectedParams(arguments, keys: ["window_id", "workspace_id", "pane_id", "surface_id"])
    }

    private func selectedParams(_ arguments: [String: Any], keys: [String]) -> [String: Any] {
        var params: [String: Any] = [:]
        for key in keys {
            if let value = stringValue(arguments[key]) {
                params[key] = value
            }
        }
        return params
    }
}

private func tool(
    name: String,
    description: String,
    properties: [String: Any],
    required: [String] = []
) -> [String: Any] {
    [
        "type": "function",
        "name": name,
        "description": description,
        "parameters": [
            "type": "object",
            "properties": properties,
            "required": required
        ]
    ]
}

private func commonTargetProperties() -> [String: Any] {
    [
        "window_id": stringProperty("Optional target window UUID."),
        "workspace_id": stringProperty("Optional target workspace UUID."),
        "pane_id": stringProperty("Optional target pane UUID."),
        "surface_id": stringProperty("Optional target surface UUID.")
    ]
}

private func stringProperty(_ description: String) -> [String: Any] {
    ["type": "string", "description": description]
}

private func integerProperty(_ description: String) -> [String: Any] {
    ["type": "integer", "description": description]
}

private func booleanProperty(_ description: String) -> [String: Any] {
    ["type": "boolean", "description": description]
}

private func stringValue(_ value: Any?) -> String? {
    guard let string = value as? String else { return nil }
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : string
}

private func intValue(_ value: Any?) -> Int? {
    if let int = value as? Int {
        return int
    }
    if let number = value as? NSNumber {
        return number.intValue
    }
    if let string = value as? String {
        return Int(string)
    }
    return nil
}

private func boolValue(_ value: Any?) -> Bool? {
    if let bool = value as? Bool {
        return bool
    }
    if let number = value as? NSNumber {
        return number.boolValue
    }
    if let string = value as? String {
        switch string.lowercased() {
        case "true", "1", "yes":
            return true
        case "false", "0", "no":
            return false
        default:
            return nil
        }
    }
    return nil
}
