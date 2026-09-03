import Darwin
import Foundation

// `cmux coderouter <status|machines|claude>`: the team-level settings of the
// cmux coderouter model plane that Cloud machines route their agents through.
// The CLI is presentation only; each verb maps to one `coderouter.*` socket
// method handled by the app's `CoderouterClient`, which holds the Stack
// session. Every other `cmux coderouter ...` verb, and all of `cmux cr ...`,
// is exec'd into the installed CodeRouter CLI before any socket is opened.
extension CMUXCLI {
    static let coderouterUsage = """
        Usage: cmux coderouter <status|machines|claude> [options]

        Team settings for the cmux coderouter model plane that Cloud machines
        route codex, claude, pi, and opencode through. Any other verb, and every
        `cmux cr ...`, runs the installed CodeRouter CLI unchanged.

          cmux coderouter status [--team <id>] [--json]
              Sign-in state, selected team, and the team's Claude upstream.

          cmux coderouter machines [--team <id>] [--json]
              30-day coderouter usage per Cloud machine (tokens, API-equivalent USD).

          cmux coderouter claude show [--team <id>] [--json]
              The upstream Cloud machines send `claude` traffic to: kind, masked
              identifier, region, last update. Secrets are never printed.

          cmux coderouter claude set oauth-token [--stdin] [--team <id>] [--json]
              Use a Claude Code OAuth token (sk-ant-oat01-...). Run
              `claude setup-token` first, then paste the token at the hidden
              prompt, or provide it in CLAUDE_CODE_OAUTH_TOKEN, or pipe it in
              with --stdin. Never pass a token as an argument.

          cmux coderouter claude set api-key [--stdin] [--team <id>] [--json]
              Use an Anthropic API key (sk-ant-...) from ANTHROPIC_API_KEY,
              --stdin, or a hidden prompt.

          cmux coderouter claude set bedrock [--region <r>] [--model <claude-id>=<bedrock-id>]... [--team <id>] [--json]
              Use Amazon Bedrock with AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY,
              and optional AWS_SESSION_TOKEN from your shell environment.
              --region defaults to AWS_REGION or AWS_DEFAULT_REGION.

          cmux coderouter claude clear [--team <id>] [--json]
              Remove the team's Claude upstream. Cloud machines lose `claude`
              until a new one is set.

        A team has exactly one Claude upstream; setting one replaces the previous.
        Requires `cmux auth login` and a team where you can manage coderouter.

        Examples:
          claude setup-token
          cmux coderouter claude set oauth-token
          cmux coderouter claude show
          cmux coderouter machines --json
        """

    /// The first-argument verbs cmux owns under `cmux coderouter`. Everything
    /// else keeps the pre-existing passthrough into the installed CodeRouter CLI,
    /// so `cmux coderouter accounts`, `cmux coderouter login`, and a bare
    /// `cmux coderouter` behave exactly as before.
    static let cmuxOwnedCoderouterVerbs: Set<String> = ["status", "machines", "claude", "help", "--help", "-h"]

    static func isCmuxOwnedCoderouterInvocation(_ args: [String]) -> Bool {
        guard let first = args.first?.lowercased() else { return false }
        return cmuxOwnedCoderouterVerbs.contains(first)
    }

    func runCoderouterCommand(commandArgs: [String], client: SocketClient, jsonOutput: Bool) throws {
        let sub = commandArgs.first?.lowercased() ?? "help"
        let rest = Array(commandArgs.dropFirst())

        switch sub {
        case "help", "--help", "-h":
            print(Self.coderouterUsage)

        case "status":
            let (teamOpt, remaining) = parseOption(rest, name: "--team")
            try rejectUnexpectedCoderouterArguments(remaining, command: "coderouter status")
            let auth = try client.sendV2(method: "auth.status")
            let signedIn = (auth["signed_in"] as? Bool) ?? false
            var upstreamResponse: [String: Any]? = nil
            var upstreamError: String? = nil
            if signedIn {
                do {
                    upstreamResponse = try client.sendV2(method: "coderouter.claude_upstream.get", params: teamParams(teamOpt))
                } catch let error as CLIError {
                    upstreamError = error.message
                }
            }
            if jsonOutput {
                var payload: [String: Any] = ["signed_in": signedIn]
                if let user = auth["user"] { payload["user"] = user }
                if let team = auth["selected_team_id"] { payload["selected_team_id"] = team }
                if let upstreamResponse {
                    payload["team_id"] = upstreamResponse["teamId"] ?? NSNull()
                    payload["claude_upstream"] = upstreamResponse["upstream"] ?? NSNull()
                }
                if let upstreamError { payload["claude_upstream_error"] = upstreamError }
                print(jsonString(payload))
                return
            }
            guard signedIn else {
                print("Not signed in. Run `cmux auth login`, then retry.")
                return
            }
            let user = auth["user"] as? [String: Any]
            let email = (user?["email"] as? String).map(Self.sanitizeForTerminal) ?? "unknown account"
            print("Signed in as \(email)")
            let teamID = (upstreamResponse?["teamId"] as? String) ?? (auth["selected_team_id"] as? String)
            if let teamID, !teamID.isEmpty {
                print("Team: \(Self.sanitizeForTerminal(teamID))")
            }
            if let upstreamError {
                print("Claude upstream: unavailable (\(upstreamError))")
            } else if let upstreamResponse {
                printClaudeUpstream(upstreamResponse["upstream"] as? [String: Any])
            }

        case "machines", "machine":
            let (teamOpt, remaining) = parseOption(rest, name: "--team")
            try rejectUnexpectedCoderouterArguments(remaining, command: "coderouter machines")
            let response = try client.sendV2(method: "coderouter.machines", params: teamParams(teamOpt))
            if jsonOutput {
                print(jsonString(response))
                return
            }
            printMachineUsage(response)

        case "claude":
            try runCoderouterClaudeCommand(commandArgs: rest, client: client, jsonOutput: jsonOutput)

        default:
            throw CLIError(message: """
                Unknown coderouter subcommand: \(sub)

                \(Self.coderouterUsage)
                """)
        }
    }

    private func runCoderouterClaudeCommand(commandArgs: [String], client: SocketClient, jsonOutput: Bool) throws {
        let sub = commandArgs.first?.lowercased() ?? "show"
        let rest = Array(commandArgs.dropFirst())

        switch sub {
        case "help", "--help", "-h":
            print(Self.coderouterUsage)

        case "show", "get", "status":
            let (teamOpt, remaining) = parseOption(rest, name: "--team")
            try rejectUnexpectedCoderouterArguments(remaining, command: "coderouter claude show")
            let response = try client.sendV2(method: "coderouter.claude_upstream.get", params: teamParams(teamOpt))
            if jsonOutput {
                print(jsonString(response))
                return
            }
            printClaudeUpstream(response["upstream"] as? [String: Any])

        case "set":
            try runCoderouterClaudeSet(commandArgs: rest, client: client, jsonOutput: jsonOutput)

        case "clear", "remove", "rm", "delete", "unset":
            let (teamOpt, remaining) = parseOption(rest, name: "--team")
            try rejectUnexpectedCoderouterArguments(remaining, command: "coderouter claude clear")
            let response = try client.sendV2(method: "coderouter.claude_upstream.clear", params: teamParams(teamOpt))
            if jsonOutput {
                print(jsonString(response))
                return
            }
            if (response["removed"] as? Bool) == true {
                print("OK Claude upstream removed. Cloud machines have no `claude` route until a new one is set.")
            } else {
                print("No Claude upstream was set.")
            }

        default:
            throw CLIError(message: """
                Unknown coderouter claude subcommand: \(sub)

                \(Self.coderouterUsage)
                """)
        }
    }

    private func runCoderouterClaudeSet(commandArgs: [String], client: SocketClient, jsonOutput: Bool) throws {
        guard let kindArg = commandArgs.first, !Self.isCoderouterFlagToken(kindArg) else {
            throw CLIError(message: """
                coderouter claude set requires a credential kind: oauth-token, api-key, or bedrock.

                \(Self.coderouterUsage)
                """)
        }
        let rest = Array(commandArgs.dropFirst())
        let (teamOpt, rem0) = parseOption(rest, name: "--team")
        var params: [String: Any] = teamParams(teamOpt)

        switch kindArg.lowercased() {
        case "oauth-token", "oauth", "claude-code":
            let forceStdin = rem0.contains("--stdin")
            try rejectUnexpectedCoderouterArguments(rem0.filter { $0 != "--stdin" }, command: "coderouter claude set oauth-token")
            let token = try readCoderouterSecret(
                label: "Claude Code OAuth token",
                envVar: "CLAUDE_CODE_OAUTH_TOKEN",
                forceStdin: forceStdin,
                hint: "Run `claude setup-token` to mint one."
            )
            guard token.hasPrefix("sk-ant-oat01-") else {
                throw CLIError(message: "That is not a Claude Code OAuth token (expected sk-ant-oat01-...). For an Anthropic API key use `cmux coderouter claude set api-key`.")
            }
            params["kind"] = "anthropic_oauth"
            params["token"] = token

        case "api-key", "apikey", "anthropic-key":
            let forceStdin = rem0.contains("--stdin")
            try rejectUnexpectedCoderouterArguments(rem0.filter { $0 != "--stdin" }, command: "coderouter claude set api-key")
            let apiKey = try readCoderouterSecret(
                label: "Anthropic API key",
                envVar: "ANTHROPIC_API_KEY",
                forceStdin: forceStdin,
                hint: "Create one in the Anthropic console."
            )
            guard apiKey.hasPrefix("sk-ant-"), !apiKey.hasPrefix("sk-ant-oat") else {
                throw CLIError(message: "That is not an Anthropic API key (expected sk-ant-...). For a Claude Code OAuth token use `cmux coderouter claude set oauth-token`.")
            }
            params["kind"] = "anthropic_api_key"
            params["apiKey"] = apiKey

        case "bedrock":
            let (regionOpt, rem1) = parseOption(rem0, name: "--region")
            var modelIDs: [String: String] = [:]
            var remaining = rem1
            while let index = remaining.firstIndex(of: "--model") {
                guard index + 1 < remaining.count else {
                    throw CLIError(message: "coderouter claude set bedrock: --model requires <claude-model-id>=<bedrock-model-id>.")
                }
                let pair = remaining[index + 1]
                guard let equals = pair.firstIndex(of: "="), equals > pair.startIndex, pair.index(after: equals) < pair.endIndex else {
                    throw CLIError(message: "coderouter claude set bedrock: --model expects <claude-model-id>=<bedrock-model-id>, got '\(Self.sanitizeForTerminal(pair))'.")
                }
                modelIDs[String(pair[..<equals])] = String(pair[pair.index(after: equals)...])
                remaining.removeSubrange(index...(index + 1))
            }
            try rejectUnexpectedCoderouterArguments(remaining, command: "coderouter claude set bedrock")
            let env = ProcessInfo.processInfo.environment
            let region = Self.nonEmpty(regionOpt) ?? Self.nonEmpty(env["AWS_REGION"]) ?? Self.nonEmpty(env["AWS_DEFAULT_REGION"])
            guard let region else {
                throw CLIError(message: "coderouter claude set bedrock requires --region <r> or AWS_REGION / AWS_DEFAULT_REGION.")
            }
            guard let accessKeyID = Self.nonEmpty(env["AWS_ACCESS_KEY_ID"]),
                  let secretAccessKey = Self.nonEmpty(env["AWS_SECRET_ACCESS_KEY"]) else {
                throw CLIError(message: "coderouter claude set bedrock reads AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY from your shell environment; export both, then retry.")
            }
            params["kind"] = "bedrock"
            params["region"] = region
            params["accessKeyId"] = accessKeyID
            params["secretAccessKey"] = secretAccessKey
            if let sessionToken = Self.nonEmpty(env["AWS_SESSION_TOKEN"]) {
                params["sessionToken"] = sessionToken
            }
            if !modelIDs.isEmpty {
                params["modelIds"] = modelIDs
            }

        default:
            throw CLIError(message: "coderouter claude set: unsupported credential kind '\(Self.sanitizeForTerminal(kindArg))'. Use oauth-token, api-key, or bedrock.")
        }

        let response = try client.sendV2(method: "coderouter.claude_upstream.set", params: params)
        if jsonOutput {
            print(jsonString(response))
            return
        }
        let upstream = response["upstream"] as? [String: Any]
        let kind = (upstream?["kind"] as? String).map(Self.sanitizeForTerminal) ?? (params["kind"] as? String) ?? "?"
        let identifier = (upstream?["identifier"] as? String).map(Self.sanitizeForTerminal) ?? ""
        let replaced = (response["created"] as? Bool) == false
        print("OK Claude upstream \(replaced ? "replaced" : "set"): \(kind)\(identifier.isEmpty ? "" : " \(identifier)")")
        if let teamID = (response["teamId"] as? String).map(Self.sanitizeForTerminal), !teamID.isEmpty {
            print("  team: \(teamID)")
        }
        if let region = (upstream?["region"] as? String).map(Self.sanitizeForTerminal), !region.isEmpty {
            print("  region: \(region)")
        }
        print("Cloud machines route `claude` through this upstream now.")
    }

    /// Secret intake order: `--stdin` (or a non-TTY stdin) reads one line from
    /// stdin; otherwise the named environment variable; otherwise a hidden
    /// terminal prompt. Argv is deliberately not an option: it leaks into shell
    /// history and process listings.
    private func readCoderouterSecret(label: String, envVar: String, forceStdin: Bool, hint: String) throws -> String {
        let stdinIsTerminal = isatty(STDIN_FILENO) == 1
        if forceStdin || !stdinIsTerminal {
            if !forceStdin, let fromEnv = Self.nonEmpty(ProcessInfo.processInfo.environment[envVar]) {
                return fromEnv
            }
            let data = FileHandle.standardInput.readDataToEndOfFile()
            let text = String(decoding: data, as: UTF8.self)
            guard let line = text.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) else {
                throw CLIError(message: "No \(label) on stdin. \(hint)")
            }
            return line
        }
        if let fromEnv = Self.nonEmpty(ProcessInfo.processInfo.environment[envVar]) {
            return fromEnv
        }
        return try readHiddenTerminalLine(prompt: "\(label) (input hidden; \(hint.lowercased().hasSuffix(".") ? String(hint.dropLast()) : hint)): ")
    }

    private func readHiddenTerminalLine(prompt: String) throws -> String {
        FileHandle.standardError.write(Data(prompt.utf8))
        var original = termios()
        let hasTerminal = tcgetattr(STDIN_FILENO, &original) == 0
        if hasTerminal {
            var hidden = original
            hidden.c_lflag &= ~tcflag_t(ECHO)
            _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &hidden)
        }
        defer {
            if hasTerminal {
                _ = tcsetattr(STDIN_FILENO, TCSANOW, &original)
            }
            FileHandle.standardError.write(Data("\n".utf8))
        }
        guard let line = readLine(strippingNewline: true) else {
            throw CLIError(message: "No input received.")
        }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CLIError(message: "No input received.")
        }
        return trimmed
    }

    private func printClaudeUpstream(_ upstream: [String: Any]?) {
        guard let upstream else {
            print("Claude upstream: none. Cloud machines cannot run `claude` until one is set:")
            print("  claude setup-token && cmux coderouter claude set oauth-token")
            return
        }
        let kind = Self.sanitizeForTerminal((upstream["kind"] as? String) ?? "?")
        let identifier = (upstream["identifier"] as? String).map(Self.sanitizeForTerminal) ?? ""
        print("Claude upstream: \(kind)\(identifier.isEmpty ? "" : " \(identifier)")")
        if let region = (upstream["region"] as? String).map(Self.sanitizeForTerminal), !region.isEmpty {
            print("  region: \(region)")
        }
        if let modelIDs = upstream["modelIds"] as? [String: Any], !modelIDs.isEmpty {
            for key in modelIDs.keys.sorted() {
                let value = (modelIDs[key] as? String).map(Self.sanitizeForTerminal) ?? "?"
                print("  model: \(Self.sanitizeForTerminal(key)) -> \(value)")
            }
        }
        if let updatedAt = (upstream["updatedAt"] as? String).map(Self.sanitizeForTerminal), !updatedAt.isEmpty {
            print("  updated: \(updatedAt)")
        }
    }

    private func printMachineUsage(_ response: [String: Any]) {
        let kind = (response["kind"] as? String) ?? "unavailable"
        guard kind == "ready" else {
            print("Machine usage is unavailable right now (the coderouter usage ledger did not answer). Retry in a moment.")
            return
        }
        let machines = (response["machines"] as? [[String: Any]]) ?? []
        let periodDays = (response["periodDays"] as? Int) ?? 30
        guard !machines.isEmpty else {
            print("No coderouter usage from Cloud machines in the last \(periodDays) days.")
            return
        }
        var totalUSD = 0.0
        var totalTokens = 0
        for machine in machines {
            let vmID = Self.sanitizeForTerminal((machine["vmId"] as? String) ?? "?")
            let name = (machine["displayName"] as? String).map(Self.sanitizeForTerminal) ?? ""
            let totals = (machine["totals"] as? [String: Any]) ?? [:]
            let tokens = Self.intValue(totals["totalTokens"]) ?? 0
            let usd = Self.doubleValue(totals["apiEquivalentUsd"]) ?? 0
            totalTokens += tokens
            totalUSD += usd
            let nameText = name.isEmpty ? "" : "  \(name)"
            print("\(vmID)\(nameText)  tokens=\(tokens)  \(Self.formatUSD(usd))")
        }
        print("Total (\(periodDays)d): \(machines.count) machine\(machines.count == 1 ? "" : "s"), tokens=\(totalTokens), \(Self.formatUSD(totalUSD)) API-equivalent")
    }

    private func teamParams(_ teamOpt: String?) -> [String: Any] {
        var params: [String: Any] = [:]
        if let teamOpt = Self.nonEmpty(teamOpt) {
            params["teamId"] = teamOpt
        }
        return params
    }

    private func rejectUnexpectedCoderouterArguments(_ args: [String], command: String) throws {
        if let unknown = args.first(where: Self.isCoderouterFlagToken) {
            throw CLIError(message: "\(command): unknown flag '\(Self.sanitizeForTerminal(unknown))'.\n\n\(Self.coderouterUsage)")
        }
        if let extra = args.first {
            throw CLIError(message: "\(command): unexpected argument '\(Self.sanitizeForTerminal(extra))'.")
        }
    }

    private static func isCoderouterFlagToken(_ value: String) -> Bool {
        value.hasPrefix("-") && value != "-"
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func intValue(_ raw: Any?) -> Int? {
        if let value = raw as? Int { return value }
        if let value = raw as? Double { return Int(value) }
        if let value = raw as? NSNumber { return value.intValue }
        return nil
    }

    private static func doubleValue(_ raw: Any?) -> Double? {
        if let value = raw as? Double { return value }
        if let value = raw as? Int { return Double(value) }
        if let value = raw as? NSNumber { return value.doubleValue }
        return nil
    }

    private static func formatUSD(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }
}
