import Foundation

extension CMUXCLI {
    func runCommandPaletteCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        let (windowOption, afterWindow) = parseOption(commandArgs, name: "--window")
        let (argumentOptions, positional) = parseRepeatedOption(afterWindow, name: "--arg")
        let arguments = try parsePaletteActionArguments(argumentOptions)
        let explicitWindowRaw = windowOption ?? windowOverride
        var params: [String: Any] = [:]
        try applyWindowOrCallerContext(
            to: &params,
            client: client,
            windowRaw: explicitWindowRaw
        )

        let subcommand = positional.first?.lowercased() ?? "list"
        switch subcommand {
        case "list":
            guard positional.count <= 1, arguments.isEmpty else {
                throw CLIError(message: String(
                    localized: "cli.palette.error.listArguments",
                    defaultValue: "palette list does not accept extra arguments"
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
                let safeID = Self.sanitizeForTerminal(id)
                let safeSignature = Self.sanitizeForTerminal(paletteActionSignature(command))
                let safeTitle = Self.sanitizeForTerminal(title)
                let shortcut = (command["shortcut_hint"] as? String)
                    .map { "\t\(Self.sanitizeForTerminal($0))" } ?? ""
                print("\(safeID)\(safeSignature)\t\(safeTitle)\(shortcut)")
            }

        case "run":
            guard positional.count == 2, !positional[1].isEmpty else {
                throw CLIError(message: String(
                    localized: "cli.palette.error.runCommandID",
                    defaultValue: "palette run requires an action id"
                ))
            }
            try runPaletteAction(
                commandID: positional[1],
                arguments: arguments,
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
                arguments: arguments,
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
        let (windowOption, afterWindow) = parseOption(afterWorkspace, name: "--window")
        var positional = afterWindow
        let hasLeadingTerminator = positional.first == "--"
        if hasLeadingTerminator {
            positional.removeFirst()
        }
        let pathTokens: [String]
        if !hasLeadingTerminator, positional.first?.lowercased() == "open" {
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
        var params: [String: Any] = ["path": absolutePath]
        if workspaceOption == nil, windowRaw == nil {
            try applyWindowOrCallerContext(to: &params, client: client, windowRaw: nil)
        } else {
            let windowID = try normalizeWindowHandle(windowRaw, client: client)
            let workspaceID = try normalizeWorkspaceHandle(
                workspaceOption,
                client: client,
                windowHandle: windowID
            )
            if let windowID { params["window_id"] = windowID }
            if let workspaceID { params["workspace_id"] = workspaceID }
        }
        let payload = try client.sendV2(method: "vscode.open", params: params)
        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
            return
        }
        let prefix = String(
            localized: "cli.vscode.openQueued",
            defaultValue: "Queued for VS Code (Inline):"
        )
        let path = (payload["path"] as? String) ?? absolutePath
        print("\(prefix) \(Self.sanitizeForTerminal(path))")
    }

    private func runPaletteAction(
        commandID: String,
        arguments: [String: String],
        params baseParams: [String: Any],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        var params = baseParams
        params["command_id"] = commandID
        params["cwd"] = FileManager.default.currentDirectoryPath
        if !arguments.isEmpty {
            params["arguments"] = arguments
        }
        let payload = try client.sendV2(method: "palette.run", params: params)
        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
            return
        }
        let prefix: String
        switch payload["status"] as? String {
        case "queued":
            prefix = String(
                localized: "cli.palette.runQueued",
                defaultValue: "Queued command palette action:"
            )
        case "presented":
            prefix = String(
                localized: "cli.palette.runPresented",
                defaultValue: "Presented command palette action:"
            )
        case "dispatched":
            prefix = String(
                localized: "cli.palette.runDispatched",
                defaultValue: "Dispatched command palette action:"
            )
        default:
            prefix = String(
                localized: "cli.palette.runSuccess",
                defaultValue: "Ran command palette action:"
            )
        }
        print("\(prefix) \(commandID)")
    }

    private func parsePaletteActionArguments(_ values: [String]) throws -> [String: String] {
        var arguments: [String: String] = [:]
        for value in values {
            guard let separator = value.firstIndex(of: "=") else {
                throw CLIError(message: String(
                    localized: "cli.palette.error.argumentFormat",
                    defaultValue: "Action arguments must use --arg name=value"
                ))
            }
            let name = value[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                throw CLIError(message: String(
                    localized: "cli.palette.error.argumentFormat",
                    defaultValue: "Action arguments must use --arg name=value"
                ))
            }
            guard arguments[name] == nil else {
                throw CLIError(message: String(
                    localized: "cli.palette.error.duplicateArgument",
                    defaultValue: "Each action argument may be supplied once"
                ))
            }
            arguments[name] = String(value[value.index(after: separator)...])
        }
        return arguments
    }

    private func paletteActionSignature(_ command: [String: Any]) -> String {
        let arguments = command["arguments"] as? [[String: Any]] ?? []
        return arguments.compactMap { argument in
            guard let name = argument["name"] as? String else { return nil }
            let required = argument["required"] as? Bool ?? false
            return required ? " <\(name)>" : " [\(name)]"
        }.joined()
    }
}
