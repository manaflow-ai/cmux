import CMUXAgentLaunch
import Foundation

/// Batch agent permission grants on the CLI side.
///
/// `cmux permissions request` only asks the app: the app shows an approval
/// panel and writes the grant store after the user approves. The
/// `PermissionRequest` hook reads that store and counts uses; neither path
/// here ever adds a grant.
extension CMUXCLI {
    /// The allow output for a Claude `PermissionRequest` covered by an
    /// approved grant, or `nil` to continue to the normal Feed card.
    static func agentPermissionGrantAnswer(
        source: String,
        hookEventName: String,
        payload: [String: Any]
    ) -> String? {
        guard source == "claude", hookEventName == "PermissionRequest" else { return nil }
        return AgentPermissionHookAutoAnswer.answerClaudePermissionRequest(
            payload: payload,
            store: AgentPermissionGrantStore(fileURL: AgentPermissionGrantStore.defaultFileURL())
        )
    }

    /// Agent session id the CLI defaults a session-scoped request to.
    /// Claude Code exports its session id to the shells it runs.
    static func agentPermissionDefaultSessionID(
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        for key in ["CLAUDE_CODE_SESSION_ID", "CMUX_AGENT_SESSION_ID"] {
            if let value = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    static let permissionsUsage = String(
        localized: "cli.permissions.usage",
        defaultValue: """
        Usage: cmux permissions <subcommand> [options]

        Ask for a batch of agent permissions once, instead of one prompt per
        tool call. cmux shows an approval panel; nothing is granted until you
        approve it there.

        Subcommands:
          request --rule <rule> [--rule <rule>...] [--session <id> | --project <dir>]
                  [--reason <text>] [--expires <duration>]
              Ask for the rules (Claude permission syntax, e.g. 'Bash(git:*)',
              'Edit(//abs/dir/**)'). Waits for your answer and prints what was
              approved. Defaults to the current agent session when one is known.
              --expires takes 30m, 2h, 7d, or seconds (default 24h, at most 30d).
          list
              List active grants with how many requests each answered.
          revoke <id> | --all
              Revoke one grant, or every grant.

        All subcommands support --json for machine-readable output.
        """
    )

    func runPermissionsNamespace(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool
    ) throws {
        if hasHelpRequest(beforeSeparator: commandArgs) {
            print(Self.permissionsUsage)
            return
        }
        guard let sub = commandArgs.first?.lowercased() else {
            throw CLIError(message: String(
                localized: "cli.permissions.error.subcommandRequired",
                defaultValue: "permissions requires a subcommand. Try: request, list, revoke"
            ))
        }
        let rest = Array(commandArgs.dropFirst())
        switch sub {
        case "request":
            let params = try permissionsRequestParams(rest)
            // The app waits up to ten minutes for the user's answer.
            let payload = try client.sendV2(method: "permissions.request", params: params, responseTimeout: 630)
            if jsonOutput {
                print(jsonString(payload))
            }
            if payload["denied"] as? Bool == true {
                throw CLIError(message: String(
                    localized: "cli.permissions.request.denied",
                    defaultValue: "The request was denied."
                ))
            }
            if !jsonOutput {
                let approved = payload["approved"] as? [String] ?? []
                print(String(format: String(
                    localized: "cli.permissions.request.approved",
                    defaultValue: "Approved grant %@:"
                ), payload["grant_id"] as? String ?? "-"))
                for rule in approved {
                    print("  " + rule)
                }
            }

        case "list", "ls":
            try Self.permissionsRejectUnexpected(rest, subcommand: "list")
            let payload = try client.sendV2(method: "permissions.list", params: [:])
            if jsonOutput {
                print(jsonString(payload))
                return
            }
            let grants = payload["grants"] as? [[String: Any]] ?? []
            if grants.isEmpty {
                print(String(localized: "cli.permissions.list.empty", defaultValue: "No active grants."))
                return
            }
            for grant in grants {
                let id = grant["id"] as? String ?? "-"
                let scope: String
                if let session = grant["session_id"] as? String {
                    scope = "session:" + session
                } else {
                    scope = "project:" + (grant["root"] as? String ?? "-")
                }
                let uses = (grant["use_count"] as? Int).map(String.init) ?? "0"
                let expires = grant["expires_at"] as? String ?? "-"
                let rules = (grant["rules"] as? [String] ?? []).joined(separator: " ")
                print("\(id)\t\(scope)\tuses=\(uses)\texpires=\(expires)\t\(rules)")
            }

        case "revoke":
            var remainder = rest
            let all = remainder.contains("--all")
            remainder.removeAll { $0 == "--all" }
            var params: [String: Any] = [:]
            if all {
                try Self.permissionsRejectUnexpected(remainder, subcommand: "revoke")
                params["all"] = true
            } else {
                guard let id = remainder.first, !id.hasPrefix("--") else {
                    throw CLIError(message: String(
                        localized: "cli.permissions.error.revokeTarget",
                        defaultValue: "permissions revoke requires a grant id or --all (see cmux permissions list)"
                    ))
                }
                try Self.permissionsRejectUnexpected(Array(remainder.dropFirst()), subcommand: "revoke")
                params["id"] = id
            }
            let payload = try client.sendV2(method: "permissions.revoke", params: params)
            if jsonOutput {
                print(jsonString(payload))
            } else {
                print(String(format: String(
                    localized: "cli.permissions.revoke.done",
                    defaultValue: "Grants revoked: %@"
                ), String(payload["revoked"] as? Int ?? 0)))
            }

        default:
            throw CLIError(message: String(format: String(
                localized: "cli.permissions.error.unknownSubcommand",
                defaultValue: "Unknown permissions subcommand '%@'. Try: request, list, revoke"
            ), sub))
        }
    }

    private func permissionsRequestParams(_ args: [String]) throws -> [String: Any] {
        // `parseOption` keeps only the last value, and --rule repeats.
        var rules: [String] = []
        var remainder: [String] = []
        var index = args.startIndex
        while index < args.endIndex {
            let arg = args[index]
            if arg == "--rule", index + 1 < args.endIndex {
                rules.append(args[index + 1])
                index += 2
                continue
            }
            if arg.hasPrefix("--rule=") {
                rules.append(String(arg.dropFirst("--rule=".count)))
            } else {
                remainder.append(arg)
            }
            index += 1
        }
        let (session, rem0) = parseOption(remainder, name: "--session")
        let (project, rem1) = parseOption(rem0, name: "--project")
        let (reason, rem2) = parseOption(rem1, name: "--reason")
        let (expires, rem3) = parseOption(rem2, name: "--expires")
        try Self.permissionsRejectUnexpected(rem3, subcommand: "request")
        guard !rules.isEmpty else {
            throw CLIError(message: String(
                localized: "cli.permissions.error.ruleRequired",
                defaultValue: "permissions request requires at least one --rule, e.g. --rule 'Bash(git:*)'"
            ))
        }
        var params: [String: Any] = ["rules": rules]
        switch (session, project) {
        case (.some, .some):
            throw CLIError(message: String(
                localized: "cli.permissions.error.oneScope",
                defaultValue: "Use either --session or --project, not both."
            ))
        case (.some(let session), nil):
            params["scope"] = "session"
            params["session_id"] = session
        case (nil, .some(let project)):
            params["scope"] = "project"
            params["root"] = URL(fileURLWithPath: (project as NSString).expandingTildeInPath).standardizedFileURL.path
        case (nil, nil):
            guard let session = Self.agentPermissionDefaultSessionID() else {
                throw CLIError(message: String(
                    localized: "cli.permissions.error.scopeRequired",
                    defaultValue: "No agent session found. Pass --session <id> or --project <dir>."
                ))
            }
            params["scope"] = "session"
            params["session_id"] = session
        }
        if let reason { params["reason"] = reason }
        if let expires {
            guard let seconds = AgentPermissionGrantDuration.seconds(from: expires) else {
                throw CLIError(message: String(
                    localized: "cli.permissions.error.invalidExpires",
                    defaultValue: "--expires takes a duration like 30m, 2h, or 7d"
                ))
            }
            params["expires_in_seconds"] = Int(seconds)
        }
        return params
    }

    /// Fail closed on anything unrecognized, so a typo never reads as a
    /// different request.
    private static func permissionsRejectUnexpected(_ remainder: [String], subcommand: String) throws {
        guard let unexpected = remainder.first else { return }
        throw CLIError(message: String(format: String(
            localized: "cli.permissions.error.unexpectedArgument",
            defaultValue: "Unexpected argument '%@' for cmux permissions %@"
        ), unexpected, subcommand))
    }
}
