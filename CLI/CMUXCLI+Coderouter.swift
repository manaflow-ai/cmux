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
              Sign-in state, selected team, and the team's Claude upstream accounts.

          cmux coderouter machines [--team <id>] [--json]
              30-day coderouter usage per Cloud machine (tokens, API-equivalent USD).

          cmux coderouter claude list [--team <id>] [--json]
              Every Claude upstream account of the team: id, kind, masked
              identifier, label, health. Secrets are never printed. Alias: show.

          cmux coderouter claude add oauth-token [--label <s>] [--stdin] [--team <id>] [--json]
              Add a Claude Code OAuth token (sk-ant-oat01-...). Run
              `claude setup-token` to mint one automatically, or provide it in
              CLAUDE_CODE_OAUTH_TOKEN, or pipe it in with --stdin. Never pass
              a token as an argument. Alias: set.

          cmux coderouter claude add api-key [--label <s>] [--stdin] [--team <id>] [--json]
              Add an Anthropic API key (sk-ant-...) from ANTHROPIC_API_KEY,
              --stdin, or a hidden prompt.

          cmux coderouter claude add bedrock [--label <s>] [--region <r>] [--model <claude-id>=<bedrock-id>]... [--team <id>] [--json]
              Add Amazon Bedrock credentials from AWS_ACCESS_KEY_ID,
              AWS_SECRET_ACCESS_KEY, and optional AWS_SESSION_TOKEN in your
              shell environment. --region defaults to AWS_REGION or
              AWS_DEFAULT_REGION.

          cmux coderouter claude remove <account> [--team <id>] [--json]
              Remove one account by id, label, or masked identifier.

          cmux coderouter claude disable <account> | enable <account> [--team <id>] [--json]
              Take an account out of rotation, or put it back.

          cmux coderouter claude clear [--team <id>] [--json]
              Remove every Claude upstream account of the team.

        A team routes each Cloud machine to one of its accounts and moves it to
        another when that account is rate limited, rejected, or unavailable.
        Requires `cmux auth login` and a team where you can manage coderouter.

        Examples:
          cmux coderouter claude add oauth-token --label work
          cmux coderouter claude list
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
            var accountsResponse: [String: Any]? = nil
            var accountsError: String? = nil
            if signedIn {
                do {
                    accountsResponse = try client.sendV2(method: "coderouter.claude_upstream.get", params: teamParams(teamOpt))
                } catch let error as CLIError {
                    accountsError = error.message
                }
            }
            if jsonOutput {
                var payload: [String: Any] = ["signed_in": signedIn]
                if let user = auth["user"] { payload["user"] = user }
                if let team = auth["selected_team_id"] { payload["selected_team_id"] = team }
                if let accountsResponse {
                    payload["team_id"] = accountsResponse["teamId"] ?? NSNull()
                    payload["claude_accounts"] = accountsResponse["accounts"] ?? []
                }
                if let accountsError { payload["claude_accounts_error"] = accountsError }
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
            let teamID = (accountsResponse?["teamId"] as? String) ?? (auth["selected_team_id"] as? String)
            if let teamID, !teamID.isEmpty {
                print("Team: \(Self.sanitizeForTerminal(teamID))")
            }
            if let accountsError {
                print("Claude upstream accounts: unavailable (\(accountsError))")
            } else if let accountsResponse {
                printClaudeAccounts(accountsResponse)
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
        let sub = commandArgs.first?.lowercased() ?? "list"
        let rest = Array(commandArgs.dropFirst())

        switch sub {
        case "help", "--help", "-h":
            print(Self.coderouterUsage)

        case "list", "ls", "show", "get", "status":
            let (teamOpt, remaining) = parseOption(rest, name: "--team")
            try rejectUnexpectedCoderouterArguments(remaining, command: "coderouter claude list")
            let response = try client.sendV2(method: "coderouter.claude_upstream.get", params: teamParams(teamOpt))
            if jsonOutput {
                print(jsonString(response))
                return
            }
            printClaudeAccounts(response)

        case "add", "set":
            try runCoderouterClaudeAdd(commandArgs: rest, client: client, jsonOutput: jsonOutput)

        case "remove", "rm", "delete":
            let (teamOpt, remaining) = parseOption(rest, name: "--team")
            let selector = try singleCoderouterSelector(remaining, command: "coderouter claude remove")
            let account = try resolveClaudeAccount(selector, client: client, teamOpt: teamOpt)
            var params = teamParams(teamOpt)
            params["accountId"] = account.id
            let response = try client.sendV2(method: "coderouter.claude_upstream.remove", params: params)
            if jsonOutput {
                print(jsonString(response))
                return
            }
            if (response["removed"] as? Bool) == true {
                print("OK removed \(account.summary)")
            } else {
                print("No Claude upstream account \(account.summary) exists.")
            }

        case "disable", "enable":
            let (teamOpt, remaining) = parseOption(rest, name: "--team")
            let selector = try singleCoderouterSelector(remaining, command: "coderouter claude \(sub)")
            let account = try resolveClaudeAccount(selector, client: client, teamOpt: teamOpt)
            var params = teamParams(teamOpt)
            params["accountId"] = account.id
            params["state"] = sub == "disable" ? "disabled" : "active"
            let response = try client.sendV2(method: "coderouter.claude_upstream.update", params: params)
            if jsonOutput {
                print(jsonString(response))
                return
            }
            print("OK \(sub == "disable" ? "disabled" : "enabled") \(account.summary)")

        case "clear", "remove-all", "unset":
            let (teamOpt, remaining) = parseOption(rest, name: "--team")
            try rejectUnexpectedCoderouterArguments(remaining, command: "coderouter claude clear")
            let response = try client.sendV2(method: "coderouter.claude_upstream.clear", params: teamParams(teamOpt))
            if jsonOutput {
                print(jsonString(response))
                return
            }
            if (response["removed"] as? Bool) == true {
                let count = Self.intValue(response["count"]) ?? 0
                print("OK removed \(count) Claude upstream account\(count == 1 ? "" : "s"). Cloud machines have no `claude` route until a new one is added.")
            } else {
                print("No Claude upstream accounts were set.")
            }

        default:
            throw CLIError(message: """
                Unknown coderouter claude subcommand: \(sub)

                \(Self.coderouterUsage)
                """)
        }
    }

    private func runCoderouterClaudeAdd(commandArgs: [String], client: SocketClient, jsonOutput: Bool) throws {
        guard let kindArg = commandArgs.first, !Self.isCoderouterFlagToken(kindArg) else {
            throw CLIError(message: """
                coderouter claude add requires a credential kind: oauth-token, api-key, or bedrock.

                \(Self.coderouterUsage)
                """)
        }
        let rest = Array(commandArgs.dropFirst())
        let (teamOpt, rem0) = parseOption(rest, name: "--team")
        let (labelOpt, rem1) = parseOption(rem0, name: "--label")
        var params: [String: Any] = teamParams(teamOpt)
        if let label = Self.nonEmpty(labelOpt) {
            params["label"] = label
        }

        switch kindArg.lowercased() {
        case "oauth-token", "oauth", "claude-code":
            let forceStdin = rem1.contains("--stdin")
            try rejectUnexpectedCoderouterArguments(rem1.filter { $0 != "--stdin" }, command: "coderouter claude add oauth-token")
            let token = try readCoderouterSecret(
                label: "Claude Code OAuth token",
                envVar: "CLAUDE_CODE_OAUTH_TOKEN",
                forceStdin: forceStdin,
                hint: "Run `claude setup-token` to mint one."
            )
            guard token.hasPrefix("sk-ant-oat01-") else {
                throw CLIError(message: "That is not a Claude Code OAuth token (expected sk-ant-oat01-...). For an Anthropic API key use `cmux coderouter claude add api-key`.")
            }
            params["kind"] = "anthropic_oauth"
            params["token"] = token

        case "api-key", "apikey", "anthropic-key":
            let forceStdin = rem1.contains("--stdin")
            try rejectUnexpectedCoderouterArguments(rem1.filter { $0 != "--stdin" }, command: "coderouter claude add api-key")
            let apiKey = try readCoderouterSecret(
                label: "Anthropic API key",
                envVar: "ANTHROPIC_API_KEY",
                forceStdin: forceStdin,
                hint: "Create one in the Anthropic console."
            )
            guard apiKey.hasPrefix("sk-ant-"), !apiKey.hasPrefix("sk-ant-oat") else {
                throw CLIError(message: "That is not an Anthropic API key (expected sk-ant-...). For a Claude Code OAuth token use `cmux coderouter claude add oauth-token`.")
            }
            params["kind"] = "anthropic_api_key"
            params["apiKey"] = apiKey

        case "bedrock":
            let (regionOpt, rem2) = parseOption(rem1, name: "--region")
            var modelIDs: [String: String] = [:]
            var remaining = rem2
            while let index = remaining.firstIndex(of: "--model") {
                guard index + 1 < remaining.count else {
                    throw CLIError(message: "coderouter claude add bedrock: --model requires <claude-model-id>=<bedrock-model-id>.")
                }
                let pair = remaining[index + 1]
                guard let equals = pair.firstIndex(of: "="), equals > pair.startIndex, pair.index(after: equals) < pair.endIndex else {
                    throw CLIError(message: "coderouter claude add bedrock: --model expects <claude-model-id>=<bedrock-model-id>, got '\(Self.sanitizeForTerminal(pair))'.")
                }
                modelIDs[String(pair[..<equals])] = String(pair[pair.index(after: equals)...])
                remaining.removeSubrange(index...(index + 1))
            }
            try rejectUnexpectedCoderouterArguments(remaining, command: "coderouter claude add bedrock")
            let env = ProcessInfo.processInfo.environment
            let region = Self.nonEmpty(regionOpt) ?? Self.nonEmpty(env["AWS_REGION"]) ?? Self.nonEmpty(env["AWS_DEFAULT_REGION"])
            guard let region else {
                throw CLIError(message: "coderouter claude add bedrock requires --region <r> or AWS_REGION / AWS_DEFAULT_REGION.")
            }
            guard let accessKeyID = Self.nonEmpty(env["AWS_ACCESS_KEY_ID"]),
                  let secretAccessKey = Self.nonEmpty(env["AWS_SECRET_ACCESS_KEY"]) else {
                throw CLIError(message: "coderouter claude add bedrock reads AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY from your shell environment; export both, then retry.")
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
            throw CLIError(message: "coderouter claude add: unsupported credential kind '\(Self.sanitizeForTerminal(kindArg))'. Use oauth-token, api-key, or bedrock.")
        }

        let response = try client.sendV2(method: "coderouter.claude_upstream.add", params: params)
        if jsonOutput {
            print(jsonString(response))
            return
        }
        let account = (response["account"] as? [String: Any]) ?? (response["upstream"] as? [String: Any])
        let kind = (account?["kind"] as? String).map(Self.sanitizeForTerminal) ?? (params["kind"] as? String) ?? "?"
        let identifier = (account?["identifier"] as? String).map(Self.sanitizeForTerminal) ?? ""
        let label = (account?["label"] as? String).map(Self.sanitizeForTerminal) ?? ""
        print("OK added Claude upstream account: \(kind)\(identifier.isEmpty ? "" : " \(identifier)")\(label.isEmpty ? "" : " (\(label))")")
        if let id = (account?["id"] as? String).map(Self.sanitizeForTerminal), !id.isEmpty {
            print("  id: \(id)")
        }
        if let teamID = (response["teamId"] as? String).map(Self.sanitizeForTerminal), !teamID.isEmpty {
            print("  team: \(teamID)")
        }
        if let region = (account?["region"] as? String).map(Self.sanitizeForTerminal), !region.isEmpty {
            print("  region: \(region)")
        }
        if let total = Self.intValue(response["accountsTotal"]) {
            print("Cloud machines now route `claude` across \(total) account\(total == 1 ? "" : "s").")
        }
    }

    /// Secret intake order: `--stdin` (or a non-TTY stdin) reads one line from
    /// stdin; otherwise the named environment variable; for Claude Code OAuth,
    /// a terminal runs `claude setup-token` and parses its output; otherwise a
    /// hidden terminal prompt. Argv is deliberately not an option: it leaks
    /// into shell history and process listings.
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
        if envVar == "CLAUDE_CODE_OAUTH_TOKEN",
           let setupToken = try runClaudeSetupToken() {
            return setupToken
        }
        return try readHiddenTerminalLine(prompt: "\(label) (input hidden; \(hint.lowercased().hasSuffix(".") ? String(hint.dropLast()) : hint)): ")
    }

    private func runClaudeSetupToken() throws -> String? {
        let scriptPath = "/usr/bin/script"
        guard FileManager.default.isExecutableFile(atPath: scriptPath) else {
            return nil
        }
        FileHandle.standardError.write(Data("Running `claude setup-token`; finish the sign-in in your browser.\n".utf8))

        let outputPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: scriptPath)
        process.arguments = ["-q", "/dev/null", "/usr/bin/env", "claude", "setup-token"]
        process.standardInput = FileHandle.standardInput
        process.standardOutput = outputPipe
        process.standardError = FileHandle.standardError
        do {
            try process.run()
        } catch {
            return nil
        }
        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return nil
        }

        let text = String(decoding: output, as: UTF8.self)
        Self.printRedactedClaudeSetupOutput(text)
        return Self.firstClaudeSetupToken(in: text)
    }

    private static let claudeSetupTokenRegex = try! NSRegularExpression(
        pattern: #"sk-ant-oat01-[A-Za-z0-9_-]{20,1000}"#
    )

    private static func firstClaudeSetupToken(in text: String) -> String? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = claudeSetupTokenRegex.firstMatch(in: text, range: range),
              let tokenRange = Range(match.range, in: text) else {
            return nil
        }
        return String(text[tokenRange])
    }

    private static func printRedactedClaudeSetupOutput(_ text: String) {
        guard !text.isEmpty else { return }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let redacted = claudeSetupTokenRegex.stringByReplacingMatches(
            in: text,
            range: range,
            withTemplate: "[REDACTED]"
        )
        print(redacted, terminator: "")
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

    // MARK: Account listing and selection

    private struct ClaudeAccountRef {
        let id: String
        let summary: String
    }

    private static let claudeAccountIDPattern = try! NSRegularExpression(
        pattern: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
        options: [.caseInsensitive]
    )

    /// `<account>` may be the id, the label, or the masked identifier. Ids are
    /// used as-is; anything else must match exactly one account of the team.
    private func resolveClaudeAccount(_ selector: String, client: SocketClient, teamOpt: String?) throws -> ClaudeAccountRef {
        let range = NSRange(selector.startIndex..<selector.endIndex, in: selector)
        if Self.claudeAccountIDPattern.firstMatch(in: selector, range: range) != nil {
            return ClaudeAccountRef(id: selector.lowercased(), summary: Self.sanitizeForTerminal(selector))
        }
        let response = try client.sendV2(method: "coderouter.claude_upstream.get", params: teamParams(teamOpt))
        let accounts = (response["accounts"] as? [[String: Any]]) ?? []
        let needle = selector.lowercased()
        let matches = accounts.filter { account in
            [(account["label"] as? String), (account["identifier"] as? String), (account["id"] as? String)]
                .compactMap { $0?.lowercased() }
                .contains(needle)
        }
        guard matches.count == 1, let match = matches.first, let id = match["id"] as? String else {
            if matches.isEmpty {
                throw CLIError(message: "No Claude upstream account matches '\(Self.sanitizeForTerminal(selector))'. Run `cmux coderouter claude list` and use the id, label, or identifier.")
            }
            throw CLIError(message: "'\(Self.sanitizeForTerminal(selector))' matches \(matches.count) Claude upstream accounts. Use the id from `cmux coderouter claude list`.")
        }
        return ClaudeAccountRef(id: id, summary: Self.claudeAccountSummary(match))
    }

    private func singleCoderouterSelector(_ args: [String], command: String) throws -> String {
        if let unknown = args.first(where: Self.isCoderouterFlagToken) {
            throw CLIError(message: "\(command): unknown flag '\(Self.sanitizeForTerminal(unknown))'.\n\n\(Self.coderouterUsage)")
        }
        guard let selector = args.first, !selector.isEmpty else {
            throw CLIError(message: "\(command) requires an account id, label, or identifier. Run `cmux coderouter claude list`.")
        }
        if args.count > 1 {
            throw CLIError(message: "\(command): unexpected argument '\(Self.sanitizeForTerminal(args[1]))'.")
        }
        return selector
    }

    private static func claudeAccountSummary(_ account: [String: Any]) -> String {
        let kind = sanitizeForTerminal((account["kind"] as? String) ?? "?")
        let identifier = (account["identifier"] as? String).map(sanitizeForTerminal) ?? ""
        let label = (account["label"] as? String).map(sanitizeForTerminal) ?? ""
        return "\(kind)\(identifier.isEmpty ? "" : " \(identifier)")\(label.isEmpty ? "" : " (\(label))")"
    }

    private func printClaudeAccounts(_ response: [String: Any]) {
        let accounts = (response["accounts"] as? [[String: Any]]) ?? []
        guard !accounts.isEmpty else {
            print("Claude upstream accounts: none. Cloud machines cannot run `claude` until one is added:")
            print("  claude setup-token && cmux coderouter claude add oauth-token")
            return
        }
        print("Claude upstream accounts (\(accounts.count)):")
        for account in accounts {
            let id = Self.sanitizeForTerminal((account["id"] as? String) ?? "?")
            let health = Self.claudeAccountHealth(account)
            print("  \(id)  \(Self.claudeAccountSummary(account))  \(health)")
            if let region = (account["region"] as? String).map(Self.sanitizeForTerminal), !region.isEmpty {
                print("    region: \(region)")
            }
            if let modelIDs = account["modelIds"] as? [String: Any], !modelIDs.isEmpty {
                for key in modelIDs.keys.sorted() {
                    let value = (modelIDs[key] as? String).map(Self.sanitizeForTerminal) ?? "?"
                    print("    model: \(Self.sanitizeForTerminal(key)) -> \(value)")
                }
            }
        }
    }

    private static func claudeAccountHealth(_ account: [String: Any]) -> String {
        if (account["state"] as? String) == "disabled" {
            return "disabled"
        }
        var parts: [String] = []
        if let cooldown = (account["cooldownUntil"] as? String), !cooldown.isEmpty,
           let until = ISO8601DateFormatter.coderouterFlexible.date(from: cooldown), until > Date() {
            let seconds = Int(until.timeIntervalSinceNow.rounded(.up))
            parts.append("cooling down \(seconds)s")
            if let code = (account["lastFailureCode"] as? String).map(sanitizeForTerminal), !code.isEmpty {
                parts.append(code)
            }
        } else {
            parts.append("active")
        }
        if let lastUsed = (account["lastUsedAt"] as? String), !lastUsed.isEmpty {
            parts.append("last used \(sanitizeForTerminal(lastUsed))")
        }
        return parts.joined(separator: ", ")
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

private extension ISO8601DateFormatter {
    /// Server timestamps carry fractional seconds (`2026-09-02T10:00:00.000Z`).
    static let coderouterFlexible: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
