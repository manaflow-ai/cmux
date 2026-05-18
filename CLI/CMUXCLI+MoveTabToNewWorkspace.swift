import Foundation

extension CMUXCLI {
    func applyFocusOption(_ focusOpt: String?, defaultValue: Bool? = nil, to params: inout [String: Any]) throws {
        if let focusOpt {
            guard let focus = parseBoolString(focusOpt) else {
                throw CLIError(message: "--focus must be true|false")
            }
            params["focus"] = focus
        } else if let defaultValue {
            params["focus"] = defaultValue
        }
    }

    func applyTabActionFocusOption(_ focusOpt: String?, to params: inout [String: Any]) throws {
        try applyFocusOption(focusOpt, defaultValue: false, to: &params)
    }

    func validatedSplitDirection(_ raw: String?, commandName: String) throws -> String {
        guard let direction = raw, !direction.hasPrefix("--") else {
            throw CLIError(message: "\(commandName) requires a direction")
        }
        switch direction.lowercased() {
        case "left", "right", "up", "down", "l", "r", "u", "d":
            return direction
        default:
            throw CLIError(message: "\(commandName): direction must be left|right|up|down")
        }
    }

    func rejectConflictingFocusFlags(_ commandArgs: [String]) throws {
        if commandArgs.contains("--focus"), commandArgs.contains("--no-focus") {
            throw CLIError(message: "--focus and --no-focus cannot be used together")
        }
    }

    func appendCreatedWorkspaceSummaryParts(
        from payload: [String: Any],
        idFormat: CLIIDFormat,
        to summaryParts: inout [String]
    ) {
        guard let id = payload["created_workspace_id"] as? String else { return }
        var createdWorkspacePayload: [String: Any] = ["workspace_id": id]
        if let ref = payload["created_workspace_ref"] as? String {
            createdWorkspacePayload["workspace_ref"] = ref
        }
        if let createdWorkspace = formatHandle(createdWorkspacePayload, kind: "workspace", idFormat: idFormat) {
            summaryParts.append("created_workspace=\(createdWorkspace)")
        }
    }

    func runMoveTabToNewWorkspace(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        if commandArgs.contains(where: { $0 == "--action" || $0.hasPrefix("--action=") }) {
            throw CLIError(message: "move-tab-to-new-workspace does not accept --action")
        }
        try runTabAction(
            commandArgs: ["--action", "move-to-new-workspace"] + commandArgs,
            client: client,
            jsonOutput: jsonOutput,
            idFormat: idFormat,
            windowOverride: windowOverride
        )
    }

    static let moveTabToNewWorkspaceCommandHelp = """
    Usage: cmux move-tab-to-new-workspace [--tab <id|ref|index>] [--surface <id|ref|index>] [--workspace <id|ref|index>] [--title <text>] [--focus <true|false>]

    Move a tab into a newly created workspace in the same window.

    Flags:
      --tab <id|ref|index>         Target tab (accepts tab:<n> or surface:<n>; default: $CMUX_TAB_ID, then $CMUX_SURFACE_ID, then focused tab)
      --surface <id|ref|index>     Alias for --tab
      --workspace <id|ref|index>   Workspace context (default: current/$CMUX_WORKSPACE_ID)
      --title <text>               Optional title for the new workspace
      --focus <true|false>         Focus the new workspace when supported (default: false)

    Example:
      cmux move-tab-to-new-workspace --tab tab:2
      cmux move-tab-to-new-workspace --surface surface:3 --title "build logs"
    """
}

extension CMUXCLI {
    func runMoveSurface(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let surfaceRaw = optionValue(commandArgs, name: "--surface")
            ?? commandArgs.first.flatMap { $0.hasPrefix("--") ? nil : $0 }
        guard let surfaceRaw else {
            throw CLIError(message: "move-surface requires --surface <id|ref|index>")
        }

        let workspaceRaw = optionValue(commandArgs, name: "--workspace")
        let windowRaw = optionValue(commandArgs, name: "--window")
        let paneRaw = optionValue(commandArgs, name: "--pane")
        let beforeRaw = optionValue(commandArgs, name: "--before") ?? optionValue(commandArgs, name: "--before-surface")
        let afterRaw = optionValue(commandArgs, name: "--after") ?? optionValue(commandArgs, name: "--after-surface")

        let windowHandle = try normalizeWindowHandle(windowRaw, client: client)
        let workspaceHandle = try normalizeWorkspaceHandle(workspaceRaw, client: client, windowHandle: windowHandle)
        let surfaceHandle = try normalizeSurfaceHandle(surfaceRaw, client: client, workspaceHandle: workspaceHandle, allowFocused: false)
        let paneHandle = try normalizePaneHandle(paneRaw, client: client, workspaceHandle: workspaceHandle)
        let beforeHandle = try normalizeSurfaceHandle(beforeRaw, client: client, workspaceHandle: workspaceHandle)
        let afterHandle = try normalizeSurfaceHandle(afterRaw, client: client, workspaceHandle: workspaceHandle)

        var params: [String: Any] = [:]
        if let surfaceHandle { params["surface_id"] = surfaceHandle }
        if let paneHandle { params["pane_id"] = paneHandle }
        if let workspaceHandle { params["workspace_id"] = workspaceHandle }
        if let windowHandle { params["window_id"] = windowHandle }
        if let beforeHandle { params["before_surface_id"] = beforeHandle }
        if let afterHandle { params["after_surface_id"] = afterHandle }

        if let indexRaw = optionValue(commandArgs, name: "--index") {
            guard let index = Int(indexRaw) else {
                throw CLIError(message: "--index must be an integer")
            }
            params["index"] = index
        }
        if let focusRaw = optionValue(commandArgs, name: "--focus") {
            guard let focus = parseBoolString(focusRaw) else {
                throw CLIError(message: "--focus must be true|false")
            }
            params["focus"] = focus
        }

        let payload = try client.sendV2(method: "surface.move", params: params)
        let summary = "OK surface=\(formatHandle(payload, kind: "surface", idFormat: idFormat) ?? "unknown") pane=\(formatHandle(payload, kind: "pane", idFormat: idFormat) ?? "unknown") workspace=\(formatHandle(payload, kind: "workspace", idFormat: idFormat) ?? "unknown") window=\(formatHandle(payload, kind: "window", idFormat: idFormat) ?? "unknown")"
        printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: summary)
    }

    func runSplitOff(
        commandName: String,
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let (surfaceArg, rem0) = parseOption(commandArgs, name: "--surface")
        let (panelArg, rem1) = parseOption(rem0, name: "--panel")
        let (workspaceArg, rem2) = parseOption(rem1, name: "--workspace")
        let (focusOpt, rem3) = parseOption(rem2, name: "--focus")

        guard let surfaceRaw = surfaceArg ?? panelArg else {
            throw CLIError(message: "\(commandName) requires --surface <id|ref|index>")
        }
        let direction = try validatedSplitDirection(rem3.first, commandName: commandName)
        if let unknown = rem3.dropFirst().first(where: { $0.hasPrefix("--") }) {
            throw CLIError(message: "\(commandName): unknown flag '\(unknown)'")
        }

        var params: [String: Any] = ["direction": direction]
        let workspaceHandle = try normalizeWorkspaceHandle(workspaceArg, client: client)
        if let workspaceHandle { params["workspace_id"] = workspaceHandle }
        let surfaceHandle = try normalizeSurfaceHandle(surfaceRaw, client: client, workspaceHandle: workspaceHandle)
        if let surfaceHandle { params["surface_id"] = surfaceHandle }
        try applyFocusOption(focusOpt, defaultValue: false, to: &params)

        let payload = try client.sendV2(method: "surface.split_off", params: params)
        let summary = v2OKSummary(payload, idFormat: idFormat, kinds: ["surface", "pane", "workspace", "window"])
        printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: summary)
    }

    func runReorderSurface(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let surfaceRaw = optionValue(commandArgs, name: "--surface")
            ?? commandArgs.first.flatMap { $0.hasPrefix("--") ? nil : $0 }
        guard let surfaceRaw else {
            throw CLIError(message: "reorder-surface requires --surface <id|ref|index>")
        }

        let workspaceRaw = optionValue(commandArgs, name: "--workspace")
        let workspaceHandle = try normalizeWorkspaceHandle(workspaceRaw, client: client)
        let surfaceHandle = try normalizeSurfaceHandle(surfaceRaw, client: client, workspaceHandle: workspaceHandle)

        let beforeRaw = optionValue(commandArgs, name: "--before") ?? optionValue(commandArgs, name: "--before-surface")
        let afterRaw = optionValue(commandArgs, name: "--after") ?? optionValue(commandArgs, name: "--after-surface")
        let focusRaw = optionValue(commandArgs, name: "--focus")
        let beforeHandle = try normalizeSurfaceHandle(beforeRaw, client: client, workspaceHandle: workspaceHandle)
        let afterHandle = try normalizeSurfaceHandle(afterRaw, client: client, workspaceHandle: workspaceHandle)

        var params: [String: Any] = [:]
        if let surfaceHandle { params["surface_id"] = surfaceHandle }
        if let beforeHandle { params["before_surface_id"] = beforeHandle }
        if let afterHandle { params["after_surface_id"] = afterHandle }
        if let indexRaw = optionValue(commandArgs, name: "--index") {
            guard let index = Int(indexRaw) else {
                throw CLIError(message: "--index must be an integer")
            }
            params["index"] = index
        }
        try applyFocusOption(focusRaw, defaultValue: false, to: &params)

        let payload = try client.sendV2(method: "surface.reorder", params: params)
        let summary = "OK surface=\(formatHandle(payload, kind: "surface", idFormat: idFormat) ?? "unknown") pane=\(formatHandle(payload, kind: "pane", idFormat: idFormat) ?? "unknown") workspace=\(formatHandle(payload, kind: "workspace", idFormat: idFormat) ?? "unknown")"
        printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: summary)
    }
}
