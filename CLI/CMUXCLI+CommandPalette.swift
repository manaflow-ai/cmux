import Foundation

extension CMUXCLI {
    func runCommandPaletteCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        let (windowOption, positional) = parseOption(commandArgs, name: "--window")
        let windowRaw = windowOption ?? windowOverride
        var params: [String: Any] = [:]
        if let windowID = try normalizeWindowHandle(windowRaw, client: client) {
            params["window_id"] = windowID
        }

        let subcommand = positional.first?.lowercased() ?? "list"
        switch subcommand {
        case "list":
            guard positional.count <= 1 else {
                throw CLIError(message: String(
                    localized: "cli.palette.error.listArguments",
                    defaultValue: "palette list does not accept positional arguments"
                ))
            }
            let payload = try client.sendV2(method: "palette.list", params: params)
            if jsonOutput {
                print(jsonString(formatIDs(payload, mode: idFormat)))
                return
            }
            let commands = payload["commands"] as? [[String: Any]] ?? []
            for command in commands {
                guard let id = command["id"] as? String,
                      let title = command["title"] as? String else { continue }
                let shortcut = (command["shortcut_hint"] as? String).map { "\t\($0)" } ?? ""
                print("\(id)\t\(title)\(shortcut)")
            }

        case "run":
            guard positional.count == 2, !positional[1].isEmpty else {
                throw CLIError(message: String(
                    localized: "cli.palette.error.runCommandID",
                    defaultValue: "palette run requires a command id"
                ))
            }
            try runPaletteAction(
                commandID: positional[1],
                params: params,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat
            )

        default:
            guard positional.count == 1 else {
                throw CLIError(message: String(
                    localized: "cli.palette.error.unknownSubcommand",
                    defaultValue: "Unknown palette subcommand"
                ))
            }
            try runPaletteAction(
                commandID: positional[0],
                params: params,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat
            )
        }
    }

    func runInlineVSCodeCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        let (workspaceOption, afterWorkspace) = parseOption(commandArgs, name: "--workspace")
        let (windowOption, positional) = parseOption(afterWorkspace, name: "--window")
        let pathTokens: [String]
        if positional.first?.lowercased() == "open" {
            pathTokens = Array(positional.dropFirst())
        } else {
            pathTokens = positional
        }
        guard pathTokens.count <= 1 else {
            throw CLIError(message: String(
                localized: "cli.vscode.error.arguments",
                defaultValue: "vscode open accepts one directory path"
            ))
        }

        let absolutePath = URL(
            fileURLWithPath: resolvePath(pathTokens.first ?? "."),
            isDirectory: true
        ).standardizedFileURL.path
        let windowRaw = windowOption ?? windowOverride
        let windowID = try normalizeWindowHandle(windowRaw, client: client)
        let workspaceRaw = workspaceOption
            ?? (windowRaw == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
        let workspaceID = try normalizeWorkspaceHandle(
            workspaceRaw,
            client: client,
            windowHandle: windowID
        )

        var params: [String: Any] = ["path": absolutePath]
        if let windowID { params["window_id"] = windowID }
        if let workspaceID { params["workspace_id"] = workspaceID }
        let payload = try client.sendV2(method: "vscode.open", params: params)
        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
            return
        }
        let prefix = String(
            localized: "cli.vscode.openAccepted",
            defaultValue: "Opening in VS Code (Inline):"
        )
        print("\(prefix) \((payload["path"] as? String) ?? absolutePath)")
    }

    private func runPaletteAction(
        commandID: String,
        params baseParams: [String: Any],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        var params = baseParams
        params["command_id"] = commandID
        let payload = try client.sendV2(method: "palette.run", params: params)
        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
            return
        }
        let prefix = String(
            localized: "cli.palette.runSuccess",
            defaultValue: "Ran command palette action:"
        )
        print("\(prefix) \(commandID)")
    }
}
