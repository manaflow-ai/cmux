import Foundation

extension CMUXCLI {
    func runCommandPaletteCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        let (parseable, protected) = splitAtArgumentTerminator(commandArgs)
        let (targetOption, afterTarget) = parseOption(parseable, name: "--target")
        let (windowOption, afterWindow) = parseOption(afterTarget, name: "--window")
        let (argumentOptions, positional) = parseRepeatedOption(afterWindow, name: "--arg")
        let arguments = try parsePaletteActionArguments(argumentOptions)
        let explicitWindowRaw = windowOption ?? windowOverride
        try rejectBlankExplicitOption(explicitWindowRaw, name: "--window")
        try rejectBlankExplicitOption(targetOption, name: "--target")
        var params: [String: Any] = [:]
        if let targetOption {
            guard explicitWindowRaw == nil else {
                throw CLIError(message: String(
                    localized: "cli.palette.error.targetConflict",
                    defaultValue: "--target cannot be combined with --window"
                ))
            }
            params["target"] = try parseCommandPaletteTarget(targetOption)
        } else {
            try applyWindowOrCallerContext(
                to: &params,
                client: client,
                windowRaw: explicitWindowRaw
            )
        }

        let commandPositionals = positional + protected
        let subcommand = commandPositionals.first?.lowercased() ?? "list"
        switch subcommand {
        case "list":
            guard commandPositionals.count <= 1,
                  arguments.isEmpty,
                  targetOption == nil else {
                throw CLIError(message: String(
                    localized: "cli.palette.error.listArguments",
                    defaultValue: "palette list does not accept extra arguments"
                ))
            }
            let payload = try client.sendV2(method: "palette.list", params: params)
            let commands = try validatedPaletteCommands(in: payload)
            if jsonOutput {
                print(jsonString(formatIDs(payload, mode: idFormat)))
                return
            }
            for command in commands {
                guard let id = command["id"] as? String,
                      let title = command["title"] as? String else {
                    throw CLIError(message: String(
                        localized: "cli.palette.error.malformedListResponse",
                        defaultValue: "Malformed palette.list response"
                    ))
                }
                let safeID = Self.sanitizeForTerminal(id)
                let safeSignature = Self.sanitizeForTerminal(paletteActionSignature(command))
                let safeTitle = Self.sanitizeForTerminal(title)
                let shortcut = (command["shortcut_hint"] as? String)
                    .map { "\t\(Self.sanitizeForTerminal($0))" } ?? ""
                print("\(safeID)\(safeSignature)\t\(safeTitle)\(shortcut)")
            }

        case "run":
            guard commandPositionals.count == 2, !commandPositionals[1].isEmpty else {
                throw CLIError(message: String(
                    localized: "cli.palette.error.runCommandID",
                    defaultValue: "palette run requires an action id"
                ))
            }
            try runPaletteAction(
                commandID: commandPositionals[1],
                arguments: arguments,
                params: params,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat
            )

        default:
            guard commandPositionals.count == 1, !commandPositionals[0].isEmpty else {
                throw CLIError(message: String(
                    localized: "cli.palette.error.unknownSubcommand",
                    defaultValue: "Unknown palette subcommand"
                ))
            }
            try runPaletteAction(
                commandID: commandPositionals[0],
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
        let (parseable, protected) = splitAtArgumentTerminator(commandArgs)
        let (workspaceOption, afterWorkspace) = parseOption(parseable, name: "--workspace")
        let (windowOption, afterWindow) = parseOption(afterWorkspace, name: "--window")
        let pathTokens: [String]
        if afterWindow.first?.lowercased() == "open" {
            pathTokens = Array(afterWindow.dropFirst()) + protected
        } else {
            pathTokens = afterWindow + protected
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
        try rejectBlankExplicitOption(windowRaw, name: "--window")
        try rejectBlankExplicitOption(workspaceOption, name: "--workspace")
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
        guard payload["accepted"] as? Bool == true,
              payload["status"] as? String == "queued",
              let responsePath = payload["path"] as? String else {
            throw CLIError(message: String(
                localized: "cli.vscode.error.malformedResponse",
                defaultValue: "Malformed vscode.open response"
            ))
        }
        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
            return
        }
        let prefix = String(
            localized: "cli.vscode.openQueued",
            defaultValue: "Queued for VS Code (Inline):"
        )
        print("\(prefix) \(Self.sanitizeForTerminal(responsePath))")
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
        guard let status = payload["status"] as? String,
              ["completed", "queued", "presented"].contains(status),
              let command = payload["command"] as? [String: Any],
              command["id"] is String else {
            throw CLIError(message: String(
                localized: "cli.palette.error.malformedRunResponse",
                defaultValue: "Malformed palette.run response"
            ))
        }
        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
            return
        }
        let prefix: String
        switch status {
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
        default:
            prefix = String(
                localized: "cli.palette.runSuccess",
                defaultValue: "Ran command palette action:"
            )
        }
        print("\(prefix) \(Self.sanitizeForTerminal(commandID))")
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

    private func splitAtArgumentTerminator(_ arguments: [String]) -> (parseable: [String], protected: [String]) {
        guard let index = arguments.firstIndex(of: "--") else {
            return (arguments, [])
        }
        return (Array(arguments[..<index]), Array(arguments[arguments.index(after: index)...]))
    }

    private func rejectBlankExplicitOption(_ value: String?, name: String) throws {
        guard let value else { return }
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIError(message: String(
                format: String(
                    localized: "cli.error.optionRequiresValue",
                    defaultValue: "%@ requires a non-empty value"
                ),
                name
            ))
        }
    }

    private func validatedPaletteCommands(in payload: [String: Any]) throws -> [[String: Any]] {
        guard let commands = payload["commands"] as? [[String: Any]],
              commands.allSatisfy({ $0["id"] is String && $0["title"] is String }) else {
            throw CLIError(message: String(
                localized: "cli.palette.error.malformedListResponse",
                defaultValue: "Malformed palette.list response"
            ))
        }
        return commands
    }

    private func parseCommandPaletteTarget(_ rawValue: String) throws -> [String: Any] {
        func invalidTarget() -> CLIError {
            CLIError(message: String(
                localized: "cli.palette.error.invalidTargetJSON",
                defaultValue: "--target must be the JSON target object returned by palette list"
            ))
        }

        guard let data = rawValue.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let target = object as? [String: Any],
              Set(target.keys) == ["window_id", "workspace_id", "panel_id"],
              let windowID = target["window_id"] as? String,
              UUID(uuidString: windowID) != nil else {
            throw invalidTarget()
        }
        let workspaceID = target["workspace_id"]
        let panelID = target["panel_id"]
        guard workspaceID is NSNull || (workspaceID as? String).flatMap(UUID.init(uuidString:)) != nil,
              panelID is NSNull || (panelID as? String).flatMap(UUID.init(uuidString:)) != nil,
              !(panelID is String && workspaceID is NSNull) else {
            throw invalidTarget()
        }
        return target
    }

    private func paletteActionSignature(_ command: [String: Any]) -> String {
        let arguments = command["arguments"] as? [[String: Any]] ?? []
        return arguments.compactMap { argument in
            guard let name = argument["name"] as? String else { return nil }
            let required = argument["required"] as? Bool ?? false
            let valueType = argument["type"] as? String ?? "string"
            let allowsEmpty = argument["allows_empty"] as? Bool ?? false
            let valueSyntax = allowsEmpty ? "<\(valueType)|empty>" : "<\(valueType)>"
            let option = "--arg \(name)=\(valueSyntax)"
            return required ? " \(option)" : " [\(option)]"
        }.joined()
    }
}
