import Foundation

/// `cmux vault …` — the Vault session index over the control socket, so
/// terminal agents can browse, search, checkpoint, and fork agent sessions
/// exactly like the Vault UI. Read verbs never focus anything; `fork` opens
/// the new session's workspace only with an explicit `--open`.
extension CMUXCLI {
    private struct RecoverySession: Codable {
        let id: String
        let cwd: String?
        let lastMessage: String?
        let tasks: [RecoveryTask]?

        enum CodingKeys: String, CodingKey {
            case id, cwd, lastMessage = "last_message", tasks
        }
    }

    private struct RecoveryTask: Codable {
        let id: String
    }

    static let recoveryUsage = """
    Usage: cmux recover [options]

    Find interrupted local Claude sessions through sr. Pass --session to open
    one exact session in an isolated workspace running sr codex.

    Options:
      --query <text>       Filter sessions by id, path, task, or transcript text
      --session <id>       Recover one exact session in a new workspace
      --limit <n>          Maximum search results (default: 4)
      --focus              Focus the last created workspace
      --json               Print the discovered sessions as JSON; do not launch
    """

    func runRecoveryCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        if hasHelpRequest(beforeSeparator: commandArgs) {
            print(Self.recoveryUsage)
            return
        }
        let (query, rem0) = parseOption(commandArgs, name: "--query")
        let (session, rem1) = parseOption(rem0, name: "--session")
        let (limitRaw, rem2) = parseOption(rem1, name: "--limit")
        var remainder = rem2
        let focus = remainder.contains("--focus")
        remainder.removeAll { $0 == "--focus" }
        try Self.vaultRejectUnexpected(remainder, subcommand: "recover")
        let limit = try Self.vaultParseLimit(limitRaw ?? "4")
        guard limit <= 500 else { throw CLIError(message: "--limit must be 1...500") }
        let sessions = try loadRecoverySessions(query: query, limit: limit, session: session)
        if jsonOutput {
            print(String(data: try JSONEncoder().encode(sessions), encoding: .utf8) ?? "[]")
            return
        }
        if session == nil {
            if sessions.isEmpty { print("No recoverable sessions found.") }
            for item in sessions {
                print("\(item.id)\t\(item.cwd ?? "")\t\(item.lastMessage ?? "")")
            }
            return
        }
        let selected = session.map { id in sessions.filter { $0.id == id } } ?? sessions
        guard !selected.isEmpty else {
            throw CLIError(message: session.map { "Recovery session \($0) was not found." } ?? "No recoverable sessions found.")
        }
        for (index, item) in selected.prefix(limit).enumerated() {
            let prompt = try loadRecoveryPrompt(sessionID: item.id)
            let quotedPrompt = "'" + prompt.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
            let command = "sr codex \(quotedPrompt)"
            var args = ["--name", "Recover · \(item.id.prefix(8))", "--cwd", item.cwd ?? NSHomeDirectory(), "--command", command]
            if focus && index == min(selected.count, limit) - 1 {
                args += ["--focus", "true"]
            } else {
                args += ["--focus", "false"]
            }
            try runWorkspaceCreateCommand(
                commandName: "recover",
                commandArgs: args,
                client: client,
                jsonOutput: false,
                idFormat: idFormat,
                windowOverride: windowOverride,
                honorJSONOutput: false
            )
        }
    }

    private func loadRecoverySessions(query: String?, limit: Int, session: String?) throws -> [RecoverySession] {
        var args = ["recover", "list", "--json", "--limit", String(limit)]
        if let session { args = ["recover", "show", "--session", session, "--json"] }
        else if let query, !query.isEmpty { args += ["--query", query] }
        let data = try runRecoverySubrouter(args)
        return try JSONDecoder().decode([RecoverySession].self, from: data)
    }

    private func loadRecoveryPrompt(sessionID: String) throws -> String {
        try String(decoding: runRecoverySubrouter(["recover", "prompt", "--session", sessionID]), as: UTF8.self)
    }

    private func runRecoverySubrouter(_ arguments: [String]) throws -> Data {
        let result = CLIProcessRunner.runProcess(
            executablePath: "/usr/bin/env",
            arguments: ["sr"] + arguments,
            timeout: 30
        )
        guard !result.timedOut, result.status == 0 else {
            throw CLIError(message: result.timedOut ? "sr recover timed out" : "sr recover failed: \(result.stderr)")
        }
        return Data(result.stdout.utf8)
    }

    static let vaultUsage = String(
        localized: "cli.vault.usage",
        defaultValue: """
        Usage: cmux vault <subcommand> [options]

        Browse, search, checkpoint, and fork agent sessions from the Vault index.

        Subcommands:
          sessions [--agent <id>] [--folder <path>] [--limit <n>]
              List indexed agent sessions, newest first.
          search <query> [--limit <n>]
              Search sessions. Supports agent:, repo:, ws:, before:/after:
              operators and quoted phrases, ranked by recency.
          checkpoints --agent <id> --session <id>
              List a session's checkpoint timeline (derived turns + manual).
          checkpoint --agent <id> --session <id> [--name <text>]
              Create a manual named checkpoint at the session's current tip.
          fork --agent <id> --session <id> (--checkpoint <id> | --turn <n>) [--open]
              Fork a new session from a checkpoint. Prints the new session id
              and its resume command; --open also opens it in a new workspace.

        All subcommands support --json for machine-readable output.
        """
    )

    func runVaultNamespace(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool
    ) throws {
        if hasHelpRequest(beforeSeparator: commandArgs) {
            print(Self.vaultUsage)
            return
        }
        guard let sub = commandArgs.first?.lowercased() else {
            throw CLIError(message: String(
                localized: "cli.vault.error.subcommandRequired",
                defaultValue: "vault requires a subcommand. Try: sessions, search, checkpoints, checkpoint, fork"
            ))
        }
        let rest = Array(commandArgs.dropFirst())
        switch sub {
        case "sessions", "ls":
            let (agent, rem0) = parseOption(rest, name: "--agent")
            let (folder, rem1) = parseOption(rem0, name: "--folder")
            let (limit, rem2) = parseOption(rem1, name: "--limit")
            try Self.vaultRejectUnexpected(rem2, subcommand: "sessions")
            var params: [String: Any] = [:]
            if let agent { params["agent"] = agent }
            if let folder { params["folder"] = folder }
            if let limit { params["limit"] = try Self.vaultParseLimit(limit) }
            let payload = try client.sendV2(method: "vault.sessions", params: params)
            printVaultSessionsPayload(payload, jsonOutput: jsonOutput)

        case "search":
            let (limit, rem0) = parseOption(rest, name: "--limit")
            let queryTerms = rem0.filter { !$0.hasPrefix("--") }
            try Self.vaultRejectUnexpected(rem0.filter { $0.hasPrefix("--") }, subcommand: "search")
            guard !queryTerms.isEmpty else {
                throw CLIError(message: String(
                    localized: "cli.vault.error.queryRequired",
                    defaultValue: "vault search requires a query. Operators: agent:, repo:, ws:, before:/after:"
                ))
            }
            var params: [String: Any] = ["query": queryTerms.joined(separator: " ")]
            if let limit { params["limit"] = try Self.vaultParseLimit(limit) }
            let payload = try client.sendV2(method: "vault.search", params: params)
            printVaultSessionsPayload(payload, jsonOutput: jsonOutput)

        case "checkpoints":
            let (selector, remainder) = try vaultSessionSelector(rest)
            try Self.vaultRejectUnexpected(remainder, subcommand: "checkpoints")
            let payload = try client.sendV2(
                method: "vault.checkpoints",
                params: ["agent": selector.agent, "session": selector.session]
            )
            printVaultCheckpointsPayload(payload, jsonOutput: jsonOutput)

        case "checkpoint":
            let (selector, selectorRemainder) = try vaultSessionSelector(rest)
            let (name, remainder) = parseOption(selectorRemainder, name: "--name")
            try Self.vaultRejectUnexpected(remainder, subcommand: "checkpoint")
            var params: [String: Any] = ["agent": selector.agent, "session": selector.session]
            if let name { params["name"] = name }
            let payload = try client.sendV2(method: "vault.checkpoint", params: params)
            if jsonOutput {
                print(jsonString(payload))
            } else if let checkpoint = payload["checkpoint"] as? [String: Any] {
                print(Self.vaultCheckpointLine(checkpoint))
            }

        case "fork":
            let (selector, selectorRemainder) = try vaultSessionSelector(rest)
            let (checkpointID, rem1) = parseOption(selectorRemainder, name: "--checkpoint")
            let (turn, rem2) = parseOption(rem1, name: "--turn")
            var remainder = rem2
            let open = remainder.contains("--open")
            remainder.removeAll { $0 == "--open" }
            try Self.vaultRejectUnexpected(remainder, subcommand: "fork")
            guard checkpointID != nil || turn != nil else {
                throw CLIError(message: String(
                    localized: "cli.vault.error.checkpointRequired",
                    defaultValue: "vault fork requires --checkpoint <id> or --turn <n> (see cmux vault checkpoints)"
                ))
            }
            guard checkpointID == nil || turn == nil else {
                throw CLIError(message: String(
                    localized: "cli.vault.error.conflictingForkSelectors",
                    defaultValue: "vault fork takes --checkpoint <id> or --turn <n>, not both"
                ))
            }
            var params: [String: Any] = ["agent": selector.agent, "session": selector.session]
            if let checkpointID { params["checkpoint"] = checkpointID }
            if let turn {
                guard let turnNumber = Int(turn), turnNumber > 0 else {
                    throw CLIError(message: String(
                        localized: "cli.vault.error.invalidTurn",
                        defaultValue: "--turn requires a positive number"
                    ))
                }
                params["turn"] = turnNumber
            }
            if open {
                params["open"] = true
                params["focus"] = true
            }
            let payload = try client.sendV2(method: "vault.fork", params: params)
            if jsonOutput {
                print(jsonString(payload))
            } else {
                if let sessionID = payload["session_id"] as? String {
                    print(String(format: String(
                        localized: "cli.vault.fork.created",
                        defaultValue: "Forked session %@"
                    ), sessionID))
                }
                if let resume = payload["resume_command"] as? String {
                    print(String(format: String(
                        localized: "cli.vault.fork.resumeHint",
                        defaultValue: "Resume with: %@"
                    ), resume))
                }
                if payload["opened"] as? Bool == true {
                    print(String(
                        localized: "cli.vault.fork.opened",
                        defaultValue: "Opened in a new workspace."
                    ))
                }
            }

        default:
            throw CLIError(message: String(format: String(
                localized: "cli.vault.error.unknownSubcommand",
                defaultValue: "Unknown vault subcommand '%@'. Try: sessions, search, checkpoints, checkpoint, fork"
            ), sub))
        }
    }

    // MARK: Parsing helpers

    private func vaultSessionSelector(
        _ args: [String]
    ) throws -> (selector: (agent: String, session: String), remainder: [String]) {
        let (agent, rem0) = parseOption(args, name: "--agent")
        let (session, rem1) = parseOption(rem0, name: "--session")
        guard let agent, !agent.hasPrefix("--"), let session, !session.hasPrefix("--") else {
            throw CLIError(message: String(
                localized: "cli.vault.error.sessionSelectorRequired",
                defaultValue: "This subcommand requires --agent <id> --session <id> (see cmux vault sessions)"
            ))
        }
        return ((agent, session), rem1)
    }

    private static func vaultParseLimit(_ raw: String) throws -> Int {
        guard let value = Int(raw), value > 0 else {
            throw CLIError(message: String(
                localized: "cli.vault.error.invalidLimit",
                defaultValue: "--limit requires a positive number"
            ))
        }
        return value
    }

    /// Fail closed on anything unrecognized: neither a typo nor a stray
    /// positional may read as a supported request.
    private static func vaultRejectUnexpected(_ remainder: [String], subcommand: String) throws {
        guard let unexpected = remainder.first else { return }
        throw CLIError(message: String(format: String(
            localized: "cli.vault.error.unexpectedArgument",
            defaultValue: "Unexpected argument '%@' for cmux vault %@"
        ), unexpected, subcommand))
    }

    // MARK: Rendering

    private func printVaultSessionsPayload(_ payload: [String: Any], jsonOutput: Bool) {
        if jsonOutput {
            print(jsonString(payload))
            return
        }
        if let errors = payload["errors"] as? [String] {
            for message in errors {
                cliWriteStderr("warning: " + message + "\n")
            }
        }
        let sessions = payload["sessions"] as? [[String: Any]] ?? []
        if sessions.isEmpty {
            print(String(localized: "cli.vault.sessions.empty", defaultValue: "No sessions."))
            return
        }
        for session in sessions {
            let agent = session["agent"] as? String ?? "-"
            let id = session["session_id"] as? String ?? "-"
            let status = session["status"] as? String ?? "-"
            let title = session["title"] as? String ?? ""
            let cwd = session["cwd"] as? String ?? ""
            let modified = session["modified"] as? String ?? ""
            print("\(agent)\t\(id)\t\(status)\t\(modified)\t\(title)\t\(cwd)")
        }
    }

    private func printVaultCheckpointsPayload(_ payload: [String: Any], jsonOutput: Bool) {
        if jsonOutput {
            print(jsonString(payload))
            return
        }
        if payload["supports_fork"] as? Bool == false {
            print(String(
                localized: "cli.vault.checkpoints.viewOnly",
                defaultValue: "note: this agent's checkpoints are view-only (fork not supported yet)"
            ))
        }
        let checkpoints = payload["checkpoints"] as? [[String: Any]] ?? []
        if checkpoints.isEmpty {
            print(String(localized: "cli.vault.checkpoints.empty", defaultValue: "No checkpoints."))
            return
        }
        for checkpoint in checkpoints {
            print(Self.vaultCheckpointLine(checkpoint))
        }
    }

    private static func vaultCheckpointLine(_ checkpoint: [String: Any]) -> String {
        let id = checkpoint["id"] as? String ?? "-"
        let source = checkpoint["source"] as? String ?? "-"
        let turn = (checkpoint["turn"] as? Int).map(String.init) ?? "-"
        let label = (checkpoint["name"] as? String)
            ?? (checkpoint["prompt"] as? String)
            ?? ""
        let sha = (checkpoint["git_sha"] as? String).map { String($0.prefix(7)) } ?? ""
        return "\(id)\t\(source)\tturn=\(turn)\t\(sha)\t\(label)"
    }
}
