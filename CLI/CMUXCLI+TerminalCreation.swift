import Foundation

extension CMUXCLI {
    /// Creates a workspace through the v2 socket API, preserving terminal
    /// command input as spawn-time input for layout-free workspaces.
    func runWorkspaceCreateCommand(
        commandName: String,
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?,
        honorJSONOutput: Bool
    ) throws {
        let (commandOpt, rem0) = try parseTerminalCreationCommandOption(
            commandArgs,
            commandName: commandName
        )
        let (cwdOpt, rem1) = parseOption(rem0, name: "--cwd")
        let (nameOpt, rem2) = parseOption(rem1, name: "--name")
        let (descriptionOpt, rem3) = parseOption(rem2, name: "--description")
        let (layoutOpt, rem4) = parseOption(rem3, name: "--layout")
        let (windowOpt, rem5) = parseOption(rem4, name: "--window")
        let (focusOpt, rem6) = parseOption(rem5, name: "--focus")
        let (groupOpt, rem7) = parseOption(rem6, name: "--group")
        let (groupPlacementOpt, rem8) = parseOption(rem7, name: "--group-placement")
        let (groupReferenceOpt, rem9) = parseOption(rem8, name: "--group-reference")
        let (envFiles, envPairs, remaining) = parseWorkspaceEnvOptions(rem9)
        if remaining.last == "--env" {
            throw CLIError(message: String(
                format: String(
                    localized: "cli.workspace.create.error.envRequiresValue",
                    defaultValue: "%@: --env requires KEY=VALUE"
                ),
                locale: .current,
                commandName
            ))
        }
        if remaining.last == "--env-file" {
            throw CLIError(message: String(
                format: String(
                    localized: "cli.workspace.create.error.envFileRequiresValue",
                    defaultValue: "%@: --env-file requires <path>"
                ),
                locale: .current,
                commandName
            ))
        }
        if let unknown = remaining.first(where: { $0.hasPrefix("--") }) {
            throw CLIError(message: String(
                format: String(
                    localized: "cli.workspace.create.error.unknownFlag",
                    defaultValue: "%@: unknown flag '%@'. Known flags: --name <title>, --description <text>, --command <text>, --cwd <path>, --env KEY=VALUE, --env-file <path>, --layout <json>, --window <id|ref|index>, --focus <true|false>, --group <id|ref>, --group-placement <afterCurrent|top|end>, --group-reference <workspace>"
                ),
                locale: .current,
                commandName,
                unknown
            ))
        }
        var params: [String: Any] = [:]
        try applyWindowOrCallerContext(to: &params, client: client, windowRaw: windowOpt ?? windowOverride)
        if let cwdOpt {
            params["cwd"] = resolvePath(cwdOpt)
        }
        if layoutOpt == nil {
            applyTerminalCreationCommandOption(commandOpt, to: &params)
        }
        if let nameOpt { params["title"] = nameOpt }
        if let descriptionOpt { params["description"] = descriptionOpt }
        if let groupOpt { params["group_id"] = groupOpt }
        if let groupPlacementOpt { params["group_placement"] = groupPlacementOpt }
        if let groupReferenceOpt { params["group_reference_workspace_id"] = groupReferenceOpt }
        let workspaceEnv = try buildWorkspaceEnvironment(
            envFiles: envFiles,
            envPairs: envPairs,
            commandName: commandName
        )
        if !workspaceEnv.isEmpty {
            params["workspace_env"] = workspaceEnv
        }
        if let layoutOpt {
            guard let layoutData = layoutOpt.data(using: .utf8),
                  let layoutObj = try? JSONSerialization.jsonObject(with: layoutData) as? [String: Any] else {
                throw CLIError(message: "\(commandName): --layout value must be a valid JSON object")
            }
            params["layout"] = layoutObj
        }
        try applyFocusOption(focusOpt, defaultValue: false, to: &params)
        let response = try client.sendV2(method: "workspace.create", params: params)
        let wsId = (response["workspace_ref"] as? String) ?? (response["workspace_id"] as? String) ?? ""
        if jsonOutput && honorJSONOutput {
            print(jsonString(formatIDs(response, mode: idFormat)))
        } else {
            print("OK \(wsId)")
        }
    }

    /// Adds nonblank command text and one Enter keystroke to creation params.
    func applyTerminalCreationCommandOption(
        _ command: String?,
        to params: inout [String: Any]
    ) {
        if let command = nonBlankTerminalCreationCommand(command) {
            params["initial_input"] = command + "\r"
        }
    }

    /// Rejects terminal-only command input for explicitly non-terminal types.
    func validateTerminalCreationCommandOption(
        _ command: String?,
        type: String?,
        commandName: String
    ) throws {
        guard nonBlankTerminalCreationCommand(command) != nil,
              let type,
              type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "terminal" else {
            return
        }
        throw CLIError(message: String(
            format: String(
                localized: "cli.terminalCreation.error.commandRequiresTerminalType",
                defaultValue: "%@: --command can only be used with --type terminal"
            ),
            locale: .current,
            commandName
        ))
    }

    /// Parses terminal-creation command text without consuming a following flag.
    func parseTerminalCreationCommandOption(
        _ args: [String],
        commandName: String
    ) throws -> (command: String?, remaining: [String]) {
        var remaining: [String] = []
        var command: String?
        var index = 0
        var pastTerminator = false

        while index < args.count {
            let argument = args[index]
            if pastTerminator || argument == "--" {
                pastTerminator = true
                remaining.append(argument)
                index += 1
                continue
            }
            if argument == "--command" {
                guard index + 1 < args.count,
                      !args[index + 1].hasPrefix("--") else {
                    throw terminalCreationCommandMissingValueError(commandName: commandName)
                }
                command = args[index + 1]
                index += 2
                continue
            }
            if argument.hasPrefix("--command=") {
                let value = String(argument.dropFirst("--command=".count))
                guard !value.isEmpty else {
                    throw terminalCreationCommandMissingValueError(commandName: commandName)
                }
                command = value
                index += 1
                continue
            }
            remaining.append(argument)
            index += 1
        }

        return (command, remaining)
    }

    private func nonBlankTerminalCreationCommand(_ command: String?) -> String? {
        guard let command,
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return command
    }

    private func terminalCreationCommandMissingValueError(commandName: String) -> CLIError {
        CLIError(message: String(
            format: String(
                localized: "cli.terminalCreation.error.commandRequiresValue",
                defaultValue: "%@: --command requires <text>"
            ),
            locale: .current,
            commandName
        ))
    }
}
