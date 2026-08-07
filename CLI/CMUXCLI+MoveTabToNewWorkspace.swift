import Foundation

extension CMUXCLI {
    func splitCommandArguments(
        commandName: String,
        commandArgs: [String]
    ) throws -> SplitCommandArguments {
        let parsed = try CLICommandArgumentParser(
            context: commandName,
            options: [
                .value("--workspace", "<id|ref|index>"),
                .value("--panel", "<id|ref|index>"),
                .value("--surface", "<id|ref|index>"),
                .value("--focus", "<true|false>"),
                .value("--window", "<id|ref|index>"),
            ]
        ).parse(commandArgs)
        let direction = try validatedSplitDirection(
            parsed.positionals.first,
            commandName: commandName
        )
        try parsed.rejectUnexpectedPositionals(allowing: 1)
        return SplitCommandArguments(
            workspace: parsed.value(for: "--workspace"),
            panel: parsed.value(for: "--panel"),
            surface: parsed.value(for: "--surface"),
            focus: parsed.value(for: "--focus"),
            window: parsed.value(for: "--window"),
            direction: direction
        )
    }

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
    Usage: cmux move-tab-to-new-workspace [--tab <id|ref|index>] [--surface <id|ref|index>] [--workspace <id|ref|index>] [--window <id|ref|index>] [--title <text>] [--focus <true|false>]

    Move a tab into a newly created workspace in the same window.

    Flags:
      --tab <id|ref|index>         Target tab (accepts tab:<n> or surface:<n>; default: $CMUX_TAB_ID, then $CMUX_SURFACE_ID, then focused tab)
      --surface <id|ref|index>     Alias for --tab
      --workspace <id|ref|index>   Workspace context (default: current/$CMUX_WORKSPACE_ID)
      --window <id|ref|index>      Window context for workspace/tab refs and indexes
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
        let arguments = try CLICommandArgumentParser(
            context: "move-surface",
            options: [
                .value("--surface", "<id|ref|index>"),
                .value("--workspace", "<id|ref|index>"),
                .value("--window", "<id|ref|index>"),
                .value("--pane", "<id|ref|index>"),
                .value("--before", "<id|ref|index>"),
                .value("--before-surface", "<id|ref|index>"),
                .value("--after", "<id|ref|index>"),
                .value("--after-surface", "<id|ref|index>"),
                .value("--index", "<index>"),
                .value("--focus", "<true|false>"),
            ]
        ).parse(commandArgs)
        try arguments.rejectUnexpectedPositionals(allowing: 1)
        let surfaceRaw = arguments.value(for: "--surface") ?? arguments.positionals.first
        guard let surfaceRaw else {
            throw CLIError(message: "move-surface requires --surface <id|ref|index>")
        }

        let workspaceRaw = arguments.value(for: "--workspace")
        let windowRaw = arguments.value(for: "--window")
        let paneRaw = arguments.value(for: "--pane")
        let beforeRaw = arguments.value(for: "--before")
            ?? arguments.value(for: "--before-surface")
        let afterRaw = arguments.value(for: "--after")
            ?? arguments.value(for: "--after-surface")

        let windowHandle = try normalizeWindowHandle(windowRaw, client: client)
        let workspaceHandle = try normalizeWorkspaceHandle(workspaceRaw, client: client, windowHandle: windowHandle)
        let surfaceHandle = try normalizeSurfaceHandle(
            surfaceRaw,
            client: client,
            allowFocused: false
        )
        let paneHandle = try normalizePaneHandle(paneRaw, client: client, workspaceHandle: workspaceHandle, windowHandle: windowHandle)
        let beforeHandle = try normalizeSurfaceHandle(beforeRaw, client: client, workspaceHandle: workspaceHandle, windowHandle: windowHandle)
        let afterHandle = try normalizeSurfaceHandle(afterRaw, client: client, workspaceHandle: workspaceHandle, windowHandle: windowHandle)

        var params: [String: Any] = [:]
        if let surfaceHandle { params["surface_id"] = surfaceHandle }
        if let paneHandle { params["pane_id"] = paneHandle }
        if let workspaceHandle { params["workspace_id"] = workspaceHandle }
        if let windowHandle { params["window_id"] = windowHandle }
        if let beforeHandle { params["before_surface_id"] = beforeHandle }
        if let afterHandle { params["after_surface_id"] = afterHandle }

        if let indexRaw = arguments.value(for: "--index") {
            guard let index = Int(indexRaw) else {
                throw CLIError(message: "--index must be an integer")
            }
            params["index"] = index
        }
        if let focusRaw = arguments.value(for: "--focus") {
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
        let arguments = try splitCommandArguments(
            commandName: commandName,
            commandArgs: commandArgs
        )

        guard let surfaceRaw = arguments.surface ?? arguments.panel else {
            throw CLIError(message: "\(commandName) requires --surface <id|ref|index>")
        }

        var params: [String: Any] = ["direction": arguments.direction]
        let windowHandle = try normalizeWindowHandle(arguments.window, client: client)
        if let windowHandle { params["window_id"] = windowHandle }
        let workspaceHandle = try normalizeWorkspaceHandle(
            arguments.workspace,
            client: client,
            windowHandle: windowHandle
        )
        if let workspaceHandle { params["workspace_id"] = workspaceHandle }
        let surfaceHandle = try normalizeSurfaceHandle(surfaceRaw, client: client, workspaceHandle: workspaceHandle, windowHandle: windowHandle)
        if let surfaceHandle { params["surface_id"] = surfaceHandle }
        try applyFocusOption(arguments.focus, defaultValue: false, to: &params)

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
        let arguments = try CLICommandArgumentParser(
            context: "reorder-surface",
            options: [
                .value("--surface", "<id|ref|index>"),
                .value("--workspace", "<id|ref|index>"),
                .value("--window", "<id|ref|index>"),
                .value("--before", "<id|ref|index>"),
                .value("--before-surface", "<id|ref|index>"),
                .value("--after", "<id|ref|index>"),
                .value("--after-surface", "<id|ref|index>"),
                .value("--index", "<index>"),
                .value("--focus", "<true|false>"),
            ]
        ).parse(commandArgs)
        try arguments.rejectUnexpectedPositionals(allowing: 1)
        let surfaceRaw = arguments.value(for: "--surface") ?? arguments.positionals.first
        guard let surfaceRaw else {
            throw CLIError(message: "reorder-surface requires --surface <id|ref|index>")
        }

        let workspaceRaw = arguments.value(for: "--workspace")
        let windowRaw = arguments.value(for: "--window")
        let windowHandle = try normalizeWindowHandle(windowRaw, client: client)
        let workspaceHandle = try normalizeWorkspaceHandle(workspaceRaw, client: client, windowHandle: windowHandle)
        let surfaceHandle = try normalizeSurfaceHandle(surfaceRaw, client: client, workspaceHandle: workspaceHandle, windowHandle: windowHandle)

        let beforeRaw = arguments.value(for: "--before")
            ?? arguments.value(for: "--before-surface")
        let afterRaw = arguments.value(for: "--after")
            ?? arguments.value(for: "--after-surface")
        let focusRaw = arguments.value(for: "--focus")
        let beforeHandle = try normalizeSurfaceHandle(beforeRaw, client: client, workspaceHandle: workspaceHandle, windowHandle: windowHandle)
        let afterHandle = try normalizeSurfaceHandle(afterRaw, client: client, workspaceHandle: workspaceHandle, windowHandle: windowHandle)

        var params: [String: Any] = [:]
        if let surfaceHandle { params["surface_id"] = surfaceHandle }
        if let windowHandle { params["window_id"] = windowHandle }
        if let workspaceHandle { params["workspace_id"] = workspaceHandle }
        if let beforeHandle { params["before_surface_id"] = beforeHandle }
        if let afterHandle { params["after_surface_id"] = afterHandle }
        if let indexRaw = arguments.value(for: "--index") {
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
