import Foundation

extension CMUXCLI {
    func runWorkspaceCloseCommand(
        commandName: String,
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?,
        requireWorkspaceFlag: Bool
    ) throws {
        let target: String?
        if requireWorkspaceFlag {
            guard let workspaceRaw = optionValue(commandArgs, name: "--workspace") else {
                throw CLIError(message: "\(commandName) requires --workspace")
            }
            target = workspaceRaw
        } else {
            let (workspaceArg, rem0) = parseOption(commandArgs, name: "--workspace")
            let (_, rem1) = parseOption(rem0, name: "--window")
            target = workspaceArg ?? rem1.first(where: { !$0.hasPrefix("--") })
        }

        var params: [String: Any] = [:]
        let winId = try normalizeWindowHandle(windowFromArgsOrOverride(commandArgs, windowOverride: windowOverride), client: client)
        if let winId { params["window_id"] = winId }
        let wsId = try normalizeWorkspaceHandle(target, client: client, windowHandle: winId)
        if let wsId { params["workspace_id"] = wsId }
        let payload = try client.sendV2(method: "workspace.close", params: params)
        if let closedWorkspaceId = (payload["workspace_id"] as? String) ?? wsId {
            try? tmuxPruneCompatWorkspaceState(workspaceId: closedWorkspaceId)
        }
        printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat, kinds: ["workspace"]))
    }

    func runWorkspaceSelectCommand(
        commandName: String,
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?,
        requireWorkspaceFlag: Bool
    ) throws {
        let target: String?
        if requireWorkspaceFlag {
            guard let workspaceRaw = optionValue(commandArgs, name: "--workspace") else {
                throw CLIError(message: "\(commandName) requires --workspace")
            }
            target = workspaceRaw
        } else {
            let (workspaceArg, rem0) = parseOption(commandArgs, name: "--workspace")
            let (_, rem1) = parseOption(rem0, name: "--window")
            target = workspaceArg ?? rem1.first(where: { !$0.hasPrefix("--") })
        }

        var params: [String: Any] = [:]
        let winId = try normalizeWindowHandle(windowFromArgsOrOverride(commandArgs, windowOverride: windowOverride), client: client)
        if let winId { params["window_id"] = winId }
        let wsId = try normalizeWorkspaceHandle(target, client: client, windowHandle: winId)
        if !requireWorkspaceFlag {
            guard let wsId else {
                throw CLIError(message: "\(commandName): could not resolve workspace handle")
            }
            params["workspace_id"] = wsId
        } else if let wsId {
            params["workspace_id"] = wsId
        }
        let payload = try client.sendV2(method: "workspace.select", params: params)
        printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat, kinds: ["workspace"]))
    }

    func runWorkspaceRenameCommand(
        commandName: String,
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?,
        mode: WorkspaceRenameCommandMode
    ) throws {
        let winId: String?
        let wsId: String
        let title: String

        switch mode {
        case .legacy:
            let (wsArg, rem0) = parseOption(commandArgs, name: "--workspace")
            let (windowOpt, rem1) = parseOption(rem0, name: "--window")
            let windowRaw = windowOpt ?? windowOverride
            let workspaceArg = wsArg ?? (windowRaw == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
            let titleArgs = rem1.dropFirst(rem1.first == "--" ? 1 : 0)
            title = titleArgs.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                throw CLIError(message: "\(commandName) requires a title")
            }
            winId = try normalizeWindowHandle(windowRaw, client: client)
            wsId = try resolveWorkspaceId(workspaceArg, client: client, windowHandle: winId)

        case .namespace:
            let (titleOpt, rem0) = parseOption(commandArgs, name: "--title")
            let (workspaceArg, rem1) = parseOption(rem0, name: "--workspace")
            let (_, rem2) = parseOption(rem1, name: "--window")
            let positional = rem2.first(where: { !$0.hasPrefix("--") })
            let target = workspaceArg ?? positional
            guard let titleOpt else {
                throw CLIError(message: "\(commandName) requires --title <new>")
            }
            title = titleOpt
            winId = try normalizeWindowHandle(windowFromArgsOrOverride(commandArgs, windowOverride: windowOverride), client: client)
            guard let normalizedWorkspaceId = try normalizeWorkspaceHandle(target, client: client, windowHandle: winId) else {
                throw CLIError(message: "\(commandName): could not resolve workspace handle")
            }
            wsId = normalizedWorkspaceId
        }

        var params: [String: Any] = ["title": title, "workspace_id": wsId]
        if let winId { params["window_id"] = winId }
        let payload = try client.sendV2(method: "workspace.rename", params: params)
        printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat, kinds: ["workspace"]))
    }

    /// Top-level `cmux workspace <subcommand>` namespace. Dispatches to the
    /// same v2 socket methods that legacy verbs use (`new-workspace`,
    /// `list-workspaces`, etc.) so behavior matches. Legacy verbs keep working
    /// unchanged for backwards compatibility.
    /// `cmux window default-display [<name>|--clear]` — read/write the shared,
    /// cross-tag default display that DEBUG cmux builds open new windows on.
    ///
    /// Persisted through ``CmuxSettings/JSONConfigStore`` in the shared
    /// `cmux.json` under `app.devWindowDisplay`, so it applies to every tagged
    /// dev build regardless of bundle id. No running app required: the value is
}
