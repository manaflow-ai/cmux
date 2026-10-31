import Foundation

/// `cmux session-priority`: the CLI face of the `session_priority.status` / `session_priority.set`
/// socket verbs. `status` (the default) lists the window's workspaces in priority order with the
/// effort cmux wants each Claude session to run at; `difficulty` and `manual` change one
/// workspace. `--workspace <id|ref|index>` picks the workspace (the caller's by default) and
/// `--window` the window, as `cmux workspace status` does.
extension CMUXCLI {
    static let sessionPriorityDifficulties: [String] = ["easy", "normal", "hard", "auto"]

    static var sessionPriorityUsage: String {
        String(
            localized: "cli.sessionPriority.usage",
            defaultValue: "Usage: cmux session-priority [status] [--window <id|ref|index>] [--json]\n       cmux session-priority difficulty <easy|normal|hard|auto> [--workspace <id|ref|index>] [--window <id|ref|index>] [--json]\n       cmux session-priority manual <on|off> [--workspace <id|ref|index>] [--window <id|ref|index>] [--json]"
        )
    }

    static var sessionPriorityHelp: String {
        sessionPriorityUsage + "\n\n" + String(localized: "cli.sessionPriority.help", defaultValue: """
        status: list the window's workspaces in priority order with their tier, difficulty and the effort and model cmux wants their Claude sessions to run at, plus what each pane is doing about it. This is the default.

        difficulty <easy|normal|hard|auto>: set a workspace's difficulty. auto clears your override.

        manual <on|off>: tell cmux a person is driving this workspace's Claude sessions (on), so it leaves their effort alone, or hand them back (off).

        Without --workspace the calling terminal's workspace is used, or the selected workspace outside cmux.
        """)
    }

    func runSessionPriority(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        if hasHelpRequest(beforeSeparator: commandArgs) {
            print(Self.sessionPriorityHelp)
            return
        }
        // Check every argument before resolving the target, which contacts the app.
        let (_, withoutWorkspace) = parseOption(commandArgs, name: "--workspace")
        let (_, withoutTarget) = parseOption(withoutWorkspace, name: "--window")
        let positionals = workspaceTodoPositionals(withoutTarget)
        let subcommand = positionals.first?.lowercased() ?? "status"
        let valueOptions: Set<String>
        let maxPositionals: Int
        switch subcommand {
        case "status":
            valueOptions = ["--window"]
            maxPositionals = positionals.isEmpty ? 0 : 1
        case "difficulty", "manual":
            valueOptions = Self.workspaceTodoTargetOptions
            maxPositionals = 2
        default:
            throw CLIError(message: String(
                format: String(
                    localized: "cli.sessionPriority.error.unknownSubcommand",
                    defaultValue: "Unknown session-priority subcommand: %@. Try: status, difficulty, manual"
                ),
                subcommand
            ))
        }
        try rejectUnexpectedArguments(
            commandArgs,
            commandName: "session-priority" + (positionals.isEmpty ? "" : " \(subcommand)"),
            valueOptions: valueOptions,
            maxPositionals: maxPositionals,
            singleDashWordsArePositionals: true
        )

        var setParams: [String: Any] = [:]
        var manualDisplay = ""
        let argument = positionals.dropFirst().first?.lowercased()
        switch subcommand {
        case "difficulty":
            guard let argument, Self.sessionPriorityDifficulties.contains(argument) else {
                throw CLIError(message: String(
                    format: String(
                        localized: "cli.sessionPriority.error.invalidDifficulty",
                        defaultValue: "Invalid difficulty: %@. Expected easy, normal, hard or auto."
                    ),
                    positionals.dropFirst().first ?? ""
                ))
            }
            setParams["difficulty"] = argument
        case "manual":
            guard let argument, argument == "on" || argument == "off" else {
                throw CLIError(message: String(
                    format: String(
                        localized: "cli.sessionPriority.error.invalidManual",
                        defaultValue: "Invalid value: %@. Expected on or off."
                    ),
                    positionals.dropFirst().first ?? ""
                ))
            }
            setParams["manual"] = argument == "on"
            manualDisplay = argument
        default:
            break
        }

        if subcommand == "status" {
            var params: [String: Any] = [:]
            let (windowArg, _) = parseOption(commandArgs, name: "--window")
            if let windowId = try normalizeWindowHandle(windowArg ?? windowOverride, client: client) {
                params["window_id"] = windowId
            }
            let payload = try client.sendV2(method: "session_priority.status", params: params)
            printSessionPriorityStatus(payload, jsonOutput: jsonOutput, idFormat: idFormat)
            return
        }
        var (params, _) = try workspaceTodoTarget(commandArgs, client: client, windowOverride: windowOverride)
        params.merge(setParams) { _, new in new }
        let payload = try client.sendV2(method: "session_priority.set", params: params)
        let workspace = formatHandle(payload, kind: "workspace", idFormat: idFormat)
            ?? (params["workspace_id"] as? String) ?? ""
        let text: String
        if subcommand == "difficulty" {
            text = String(
                format: String(localized: "cli.sessionPriority.difficultySet", defaultValue: "OK %1$@ difficulty %2$@"),
                workspace,
                argument ?? ""
            )
        } else {
            text = String(
                format: String(localized: "cli.sessionPriority.manualSet", defaultValue: "OK %1$@ manual %2$@"),
                workspace,
                manualDisplay
            )
        }
        printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: text)
    }

    /// `session priority: on, urgent: 2`, then one line per workspace in rank order:
    /// `1. <workspace>  urgent  hard(override)  → high / opus  [applying]`.
    private func printSessionPriorityStatus(_ payload: [String: Any], jsonOutput: Bool, idFormat: CLIIDFormat) {
        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
            return
        }
        let enabled = payload["enabled"] as? Bool ?? false
        let urgent = (payload["urgent_count"] as? NSNumber)?.intValue ?? 0
        var lines = [String(
            format: String(
                localized: "cli.sessionPriority.status.header",
                defaultValue: "session priority: %1$@, urgent: %2$@"
            ),
            enabled ? "on" : "off",
            String(urgent)
        )]
        let workspaces = payload["workspaces"] as? [[String: Any]] ?? []
        for (offset, workspace) in workspaces.enumerated() {
            var columns = [
                "\(offset + 1). " + (formatHandle(workspace, kind: "workspace", idFormat: idFormat) ?? "?"),
                workspace["tier"] as? String ?? "-",
                "\(workspace["difficulty"] as? String ?? "-")(\(workspace["difficulty_source"] as? String ?? "-"))",
            ]
            if let target = workspace["target"] as? [String: Any] {
                var text = "→ " + (target["effort"] as? String ?? "-")
                if let model = target["model"] as? String { text += " / " + model }
                columns.append(text)
            }
            if workspace["manual"] as? Bool == true {
                columns.append(String(localized: "cli.sessionPriority.status.manual", defaultValue: "manual"))
            }
            var states: [String] = []
            for pane in workspace["panes"] as? [[String: Any]] ?? [] {
                if let state = pane["state"] as? String, !states.contains(state) { states.append(state) }
            }
            if !states.isEmpty { columns.append("[" + states.joined(separator: ", ") + "]") }
            lines.append(columns.joined(separator: "  "))
        }
        print(lines.joined(separator: "\n"))
    }
}
