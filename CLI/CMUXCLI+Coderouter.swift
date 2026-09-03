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
        Usage: cmux coderouter <accounts|machines> [options]

        The accounts a team routes its Cloud machines through: ChatGPT Codex and
        OpenCode Go subscriptions, Claude Code OAuth tokens, Anthropic API keys,
        Amazon Bedrock credentials. Any other verb, and every `cmux cr ...`, runs
        the installed CodeRouter CLI unchanged.

          cmux coderouter accounts [--team <id>] [--json]
              Every account with kind, label, masked identifier, state, usage.

          cmux coderouter accounts add [claude|codex|opencode|anthropic-key|bedrock] [--label <s>] [--stdin] [--team <id>] [--json]
              Add one account. Without a kind, cmux infers it from
              CLAUDE_CODE_OAUTH_TOKEN, ANTHROPIC_API_KEY, AWS_ACCESS_KEY_ID, or a
              pasted secret, and asks in a terminal otherwise. Secrets come from
              the environment, --stdin, or a hidden prompt, never from argv.
              claude: run `claude setup-token` first. codex and opencode hand off
              to the CodeRouter CLI sign-in (`cr add codex`).
              bedrock: --region <r> (default AWS_REGION) and --model <claude-id>=<bedrock-id>.

          cmux coderouter accounts remove <account> [--team <id>] [--json]
              <account> is an id prefix, a label, or a masked identifier that
              matches exactly one account.

          cmux coderouter accounts pause <account> | resume <account>
              Take a Claude account out of routing, or put it back.

          cmux coderouter machines [--team <id>] [--json]
              30-day coderouter usage per Cloud machine (tokens, API-equivalent USD).

        Older spellings keep working: status, claude <list|add|remove|enable|disable|clear>,
        subscriptions <list|add|remove>.

        Examples:
          claude setup-token && cmux coderouter accounts add claude --label work
          cmux coderouter accounts
          cmux coderouter accounts remove work
        """

    /// The first-argument verbs cmux owns under `cmux coderouter`. Everything
    /// else keeps the pre-existing passthrough into the installed CodeRouter CLI,
    /// so `cmux coderouter accounts`, `cmux coderouter login`, and a bare
    /// `cmux coderouter` behave exactly as before.
    static let cmuxOwnedCoderouterVerbs: Set<String> = ["accounts", "status", "machines", "claude", "subscriptions", "subs", "help", "--help", "-h"]

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
                if signedIn, let subscriptions = try? client.sendV2(method: "coderouter.accounts.list", params: teamParams(teamOpt)) {
                    payload["subscription_accounts"] = subscriptions["accounts"] ?? []
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
            if let subscriptions = try? client.sendV2(method: "coderouter.accounts.list", params: teamParams(teamOpt)) {
                printSubscriptionAccounts(subscriptions)
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

        case "accounts", "account":
            try runCoderouterAccountsCommand(commandArgs: rest, client: client, jsonOutput: jsonOutput)

        case "claude":
            try runCoderouterClaudeCommand(commandArgs: rest, client: client, jsonOutput: jsonOutput)

        case "subscriptions", "subs":
            try runCoderouterSubscriptionsCommand(commandArgs: rest, client: client, jsonOutput: jsonOutput)

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

    // MARK: Unified accounts (the flat surface)

    /// Every kind a team can route through, as the user names it on the CLI.
    private enum CoderouterAccountKind: String, CaseIterable {
        case claude
        case codex
        case opencode
        case anthropicKey = "anthropic-key"
        case bedrock

        static func parse(_ raw: String) -> CoderouterAccountKind? {
            switch raw.lowercased() {
            case "claude", "claude-code", "oauth-token", "oauth", "anthropic_oauth": return .claude
            case "codex", "chatgpt": return .codex
            case "opencode", "opencode-go": return .opencode
            case "anthropic-key", "api-key", "apikey", "anthropic_api_key": return .anthropicKey
            case "bedrock", "aws": return .bedrock
            default: return nil
            }
        }

        var pickerLine: String {
            switch self {
            case .claude: return "Claude Code OAuth token (run `claude setup-token` first)"
            case .codex: return "ChatGPT Codex subscription (signs in through the CodeRouter CLI)"
            case .opencode: return "OpenCode Go subscription (signs in through the CodeRouter CLI)"
            case .anthropicKey: return "Anthropic API key"
            case .bedrock: return "Amazon Bedrock credentials (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY)"
            }
        }
    }

    /// One row of `cmux coderouter accounts`, whichever store it lives in.
    private struct UnifiedAccount {
        enum Source { case claude, subscription }
        let source: Source
        let id: String
        let kind: String
        let label: String
        let identifier: String
        let health: String
        let usage: String
        let raw: [String: Any]

        var summary: String {
            "\(kind) \(identifier.isEmpty ? label : identifier)\(identifier.isEmpty || label.isEmpty ? "" : " (\(label))")"
        }
    }

    func runCoderouterAccountsCommand(commandArgs: [String], client: SocketClient, jsonOutput: Bool) throws {
        let sub = commandArgs.first?.lowercased() ?? "list"
        let rest = Array(commandArgs.dropFirst())
        switch sub {
        case "help", "--help", "-h":
            print(Self.coderouterUsage)

        case "list", "ls":
            let (teamOpt, remaining) = parseOption(rest, name: "--team")
            try rejectUnexpectedCoderouterArguments(remaining, command: "coderouter accounts")
            let (accounts, payload) = try loadUnifiedAccounts(client: client, teamOpt: teamOpt)
            if jsonOutput {
                print(jsonString(payload))
                return
            }
            printUnifiedAccounts(accounts)

        case "add":
            try runCoderouterAccountsAdd(commandArgs: rest, client: client, jsonOutput: jsonOutput)

        case "remove", "rm", "delete":
            let (teamOpt, remaining) = parseOption(rest, name: "--team")
            let selector = try singleCoderouterSelector(remaining, command: "coderouter accounts remove")
            let account = try resolveUnifiedAccount(selector, client: client, teamOpt: teamOpt)
            var params = teamParams(teamOpt)
            params["accountId"] = account.id
            let method = account.source == .claude ? "coderouter.claude_upstream.remove" : "coderouter.accounts.remove"
            let response = try client.sendV2(method: method, params: params)
            if jsonOutput {
                print(jsonString(response))
                return
            }
            print((response["removed"] as? Bool) == true ? "OK removed \(account.summary)" : "No account \(account.summary) exists.")

        case "pause", "disable", "resume", "enable":
            let paused = sub == "pause" || sub == "disable"
            let (teamOpt, remaining) = parseOption(rest, name: "--team")
            let selector = try singleCoderouterSelector(remaining, command: "coderouter accounts \(sub)")
            let account = try resolveUnifiedAccount(selector, client: client, teamOpt: teamOpt)
            guard account.source == .claude else {
                throw CLIError(message: "\(account.summary) is a subscription; subscriptions cannot be paused. Remove it with `cmux coderouter accounts remove` instead.")
            }
            var params = teamParams(teamOpt)
            params["accountId"] = account.id
            params["state"] = paused ? "disabled" : "active"
            let response = try client.sendV2(method: "coderouter.claude_upstream.update", params: params)
            if jsonOutput {
                print(jsonString(response))
                return
            }
            print("OK \(paused ? "paused" : "resumed") \(account.summary)")

        default:
            // `cmux coderouter accounts <label>` is a common slip; point at the verbs.
            throw CLIError(message: """
                Unknown coderouter accounts subcommand: \(sub)

                \(Self.coderouterUsage)
                """)
        }
    }

    private func runCoderouterAccountsAdd(commandArgs: [String], client: SocketClient, jsonOutput: Bool) throws {
        var args = commandArgs
        let (kindFlag, rem0) = parseOption(args, name: "--kind")
        args = rem0
        var kindArg: String? = kindFlag
        if kindArg == nil, let first = args.first, !Self.isCoderouterFlagToken(first) {
            kindArg = first
            args.removeFirst()
        }
        var kind: CoderouterAccountKind? = nil
        if let kindArg {
            guard let parsed = CoderouterAccountKind.parse(kindArg) else {
                throw CLIError(message: "Unknown account kind '\(Self.sanitizeForTerminal(kindArg))'. Use claude, codex, opencode, anthropic-key, or bedrock.")
            }
            kind = parsed
        }
        let env = ProcessInfo.processInfo.environment
        let forceStdin = args.contains("--stdin")
        // A secret already read from stdin, when the kind had to be inferred from it.
        var pastedSecret: String? = nil
        if kind == nil {
            if Self.nonEmpty(env["CLAUDE_CODE_OAUTH_TOKEN"]) != nil {
                kind = .claude
            } else if Self.nonEmpty(env["ANTHROPIC_API_KEY"]) != nil {
                kind = .anthropicKey
            } else if Self.nonEmpty(env["AWS_ACCESS_KEY_ID"]) != nil, Self.nonEmpty(env["AWS_SECRET_ACCESS_KEY"]) != nil {
                kind = .bedrock
            } else if forceStdin || isatty(STDIN_FILENO) == 0 {
                let secret = try readCoderouterSecret(label: "credential", envVar: "CMUX_CODEROUTER_UNSET", forceStdin: true, hint: "Paste a Claude Code OAuth token or an Anthropic API key.")
                guard let inferred = Self.inferKind(fromSecret: secret) else {
                    throw CLIError(message: "Could not tell what that secret is. Pass the kind: cmux coderouter accounts add <claude|anthropic-key|bedrock|codex|opencode>.")
                }
                kind = inferred
                pastedSecret = secret
            } else {
                kind = try pickCoderouterAccountKind()
            }
        }
        let resolved = kind!
        var forwarded = args.filter { $0 != "--stdin" }
        if let pastedSecret {
            // Hand the already-read secret to the kind-specific path through a
            // process-local variable so it is never re-prompted or logged.
            setenv(resolved == .claude ? "CLAUDE_CODE_OAUTH_TOKEN" : "ANTHROPIC_API_KEY", pastedSecret, 1)
        } else if forceStdin {
            forwarded.append("--stdin")
        }
        switch resolved {
        case .claude:
            try runCoderouterClaudeAdd(commandArgs: ["oauth-token"] + forwarded, client: client, jsonOutput: jsonOutput)
        case .anthropicKey:
            try runCoderouterClaudeAdd(commandArgs: ["api-key"] + forwarded, client: client, jsonOutput: jsonOutput)
        case .bedrock:
            try runCoderouterClaudeAdd(commandArgs: ["bedrock"] + forwarded, client: client, jsonOutput: jsonOutput)
        case .codex, .opencode:
            try rejectUnexpectedCoderouterArguments(forwarded.filter { !$0.hasPrefix("--team") && !$0.hasPrefix("--label") }, command: "coderouter accounts add \(resolved.rawValue)")
            try runCoderouterSubscriptionsCommand(commandArgs: ["add", resolved.rawValue], client: client, jsonOutput: jsonOutput)
        }
    }

    private static func inferKind(fromSecret secret: String) -> CoderouterAccountKind? {
        if secret.hasPrefix("sk-ant-oat01-") { return .claude }
        if secret.hasPrefix("sk-ant-") { return .anthropicKey }
        if secret.hasPrefix("AKIA") || secret.hasPrefix("ASIA") { return .bedrock }
        return nil
    }

    /// Numbered menu on stderr; stdout stays clean for scripts.
    private func pickCoderouterAccountKind() throws -> CoderouterAccountKind {
        let kinds = CoderouterAccountKind.allCases
        var menu = "Add which account?\n"
        for (index, kind) in kinds.enumerated() {
            menu += "  \(index + 1)) \(kind.pickerLine)\n"
        }
        menu += "Choice [1]: "
        FileHandle.standardError.write(Data(menu.utf8))
        guard let line = readLine(strippingNewline: true) else {
            throw CLIError(message: "No choice received.")
        }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return kinds[0] }
        if let number = Int(trimmed), (1...kinds.count).contains(number) { return kinds[number - 1] }
        if let named = CoderouterAccountKind.parse(trimmed) { return named }
        throw CLIError(message: "'\(Self.sanitizeForTerminal(trimmed))' is not a choice. Use 1-\(kinds.count) or a kind name.")
    }

    private func loadUnifiedAccounts(client: SocketClient, teamOpt: String?) throws -> ([UnifiedAccount], [String: Any]) {
        let claude = try client.sendV2(method: "coderouter.claude_upstream.get", params: teamParams(teamOpt))
        let subscriptions = try client.sendV2(method: "coderouter.accounts.list", params: teamParams(teamOpt))
        var accounts: [UnifiedAccount] = []
        var unified: [[String: Any]] = []
        for account in (subscriptions["accounts"] as? [[String: Any]]) ?? [] {
            let id = (account["id"] as? String) ?? ""
            let provider = (account["provider"] as? String) ?? "?"
            let kind = provider == "opencode-go" ? "opencode" : provider
            var health = (account["state"] as? String) ?? "?"
            if let cooldown = account["cooldownUntil"] as? String, !cooldown.isEmpty,
               let until = ISO8601DateFormatter.coderouterFlexible.date(from: cooldown), until > Date() {
                health = "cooling down \(Int(until.timeIntervalSinceNow.rounded(.up)))s"
            }
            if let code = account["lastFailureCode"] as? String, !code.isEmpty { health += " (\(code))" }
            let sessions = Self.intValue(account["activeSessions"]) ?? 0
            var usage = sessions == 1 ? "1 session" : "\(sessions) sessions"
            if let raw = account["usage"] as? [String: Any], let rate = raw["rate_limit"] as? [String: Any] {
                if let primary = rate["primary_window"] as? [String: Any], let used = Self.doubleValue(primary["used_percent"]) {
                    usage += ", 5h \(Int(used.rounded()))%"
                }
                if let secondary = rate["secondary_window"] as? [String: Any], let used = Self.doubleValue(secondary["used_percent"]) {
                    usage += ", week \(Int(used.rounded()))%"
                }
            }
            accounts.append(UnifiedAccount(source: .subscription, id: id, kind: kind, label: (account["label"] as? String) ?? "", identifier: "", health: health, usage: usage, raw: account))
            unified.append(["kind": kind, "source": "subscription", "id": id, "label": account["label"] ?? "", "state": account["state"] ?? "", "details": account])
        }
        for account in (claude["accounts"] as? [[String: Any]]) ?? [] {
            let id = (account["id"] as? String) ?? ""
            let rawKind = (account["kind"] as? String) ?? "?"
            let kind = rawKind == "anthropic_oauth" ? "claude" : rawKind == "anthropic_api_key" ? "anthropic-key" : rawKind
            accounts.append(UnifiedAccount(source: .claude, id: id, kind: kind, label: (account["label"] as? String) ?? "", identifier: (account["identifier"] as? String) ?? "", health: Self.claudeAccountHealth(account), usage: (account["region"] as? String) ?? "", raw: account))
            unified.append(["kind": kind, "source": "claude", "id": id, "label": account["label"] ?? "", "identifier": account["identifier"] ?? "", "state": account["state"] ?? "", "details": account])
        }
        let payload: [String: Any] = [
            "teamId": (claude["teamId"] as? String) ?? (subscriptions["teamId"] as? String) ?? NSNull(),
            "accounts": unified,
        ]
        return (accounts, payload)
    }

    private func printUnifiedAccounts(_ accounts: [UnifiedAccount]) {
        guard !accounts.isEmpty else {
            print("No accounts. Cloud machines cannot run codex or claude until one is added:")
            print("  cmux coderouter accounts add")
            return
        }
        let rows = accounts.map { account -> [String] in
            let name = account.identifier.isEmpty ? account.label : (account.label.isEmpty ? account.identifier : "\(account.identifier) (\(account.label))")
            return [account.kind, name, account.health, account.usage, String(account.id.prefix(8))].map(Self.sanitizeForTerminal)
        }
        let header = ["KIND", "ACCOUNT", "STATE", "USAGE", "ID"]
        var widths = header.map(\.count)
        for row in rows { for (index, cell) in row.enumerated() { widths[index] = max(widths[index], cell.count) } }
        func line(_ cells: [String]) -> String {
            cells.enumerated().map { index, cell in
                index == cells.count - 1 ? cell : cell.padding(toLength: widths[index] + 2, withPad: " ", startingAt: 0)
            }.joined().trimmingCharacters(in: .whitespaces)
        }
        print(line(header))
        for row in rows { print(line(row)) }
    }

    /// Id prefix (4+ chars), label, or masked identifier; must match exactly one account of either store.
    private func resolveUnifiedAccount(_ selector: String, client: SocketClient, teamOpt: String?) throws -> UnifiedAccount {
        let (accounts, _) = try loadUnifiedAccounts(client: client, teamOpt: teamOpt)
        let needle = selector.lowercased()
        let matches = accounts.filter { account in
            account.id.lowercased() == needle
                || (needle.count >= 4 && account.id.lowercased().hasPrefix(needle))
                || account.label.lowercased() == needle
                || (!account.identifier.isEmpty && account.identifier.lowercased() == needle)
                || ((account.raw["providerAccountId"] as? String)?.lowercased() == needle)
        }
        guard matches.count == 1, let match = matches.first else {
            if matches.isEmpty {
                throw CLIError(message: "No account matches '\(Self.sanitizeForTerminal(selector))'. Run `cmux coderouter accounts` and use the id, label, or identifier.")
            }
            throw CLIError(message: "'\(Self.sanitizeForTerminal(selector))' matches \(matches.count) accounts. Use more of the id from `cmux coderouter accounts`.")
        }
        return match
    }

    // MARK: Subscription accounts (ChatGPT Codex, OpenCode Go)

    private func runCoderouterSubscriptionsCommand(commandArgs: [String], client: SocketClient, jsonOutput: Bool) throws {
        let sub = commandArgs.first?.lowercased() ?? "list"
        let rest = Array(commandArgs.dropFirst())
        switch sub {
        case "help", "--help", "-h":
            print(Self.coderouterUsage)

        case "list", "ls", "show", "status":
            let (teamOpt, remaining) = parseOption(rest, name: "--team")
            try rejectUnexpectedCoderouterArguments(remaining, command: "coderouter subscriptions list")
            let response = try client.sendV2(method: "coderouter.accounts.list", params: teamParams(teamOpt))
            if jsonOutput {
                print(jsonString(response))
                return
            }
            printSubscriptionAccounts(response)

        case "add":
            // The ChatGPT / OpenCode sign-in flow lives in the CodeRouter CLI;
            // cmux hands off to it so there is one place that owns those OAuth steps.
            let provider = rest.first?.lowercased() ?? "codex"
            guard rest.count <= 1, ["codex", "opencode"].contains(provider) else {
                throw CLIError(message: "coderouter subscriptions add takes an optional provider: codex (default) or opencode.")
            }
            do {
                try runCoderouterAlias(commandArgs: ["add", provider])
            } catch let error as CLIError where error.exitCode == 127 {
                throw CLIError(
                    message: "The CodeRouter CLI is not installed. Add the subscription with:\n  npx coderouter@latest add \(provider)\nThen run `cmux coderouter subscriptions list`.",
                    exitCode: 127
                )
            }

        case "remove", "rm", "delete":
            let (teamOpt, remaining) = parseOption(rest, name: "--team")
            let selector = try singleCoderouterSelector(remaining, command: "coderouter subscriptions remove")
            let account = try resolveSubscriptionAccount(selector, client: client, teamOpt: teamOpt)
            var params = teamParams(teamOpt)
            params["accountId"] = account.id
            let response = try client.sendV2(method: "coderouter.accounts.remove", params: params)
            if jsonOutput {
                print(jsonString(response))
                return
            }
            if (response["removed"] as? Bool) == true {
                print("OK removed \(account.summary)")
                if (response["lastAccount"] as? Bool) == true {
                    print("That was the last subscription: Codex sessions from Cloud machines fail until one is added.")
                }
            } else {
                print("No subscription account \(account.summary) exists.")
            }

        default:
            throw CLIError(message: """
                Unknown coderouter subscriptions subcommand: \(sub)

                \(Self.coderouterUsage)
                """)
        }
    }

    private func resolveSubscriptionAccount(_ selector: String, client: SocketClient, teamOpt: String?) throws -> ClaudeAccountRef {
        let range = NSRange(selector.startIndex..<selector.endIndex, in: selector)
        if Self.claudeAccountIDPattern.firstMatch(in: selector, range: range) != nil {
            return ClaudeAccountRef(id: selector.lowercased(), summary: Self.sanitizeForTerminal(selector))
        }
        let response = try client.sendV2(method: "coderouter.accounts.list", params: teamParams(teamOpt))
        let accounts = (response["accounts"] as? [[String: Any]]) ?? []
        let needle = selector.lowercased()
        let matches = accounts.filter { account in
            [(account["label"] as? String), (account["providerAccountId"] as? String), (account["id"] as? String)]
                .compactMap { $0?.lowercased() }
                .contains(needle)
        }
        guard matches.count == 1, let match = matches.first, let id = match["id"] as? String else {
            if matches.isEmpty {
                throw CLIError(message: "No subscription account matches '\(Self.sanitizeForTerminal(selector))'. Run `cmux coderouter subscriptions list` and use the id, label, or provider account id.")
            }
            throw CLIError(message: "'\(Self.sanitizeForTerminal(selector))' matches \(matches.count) subscription accounts. Use the id from `cmux coderouter subscriptions list`.")
        }
        return ClaudeAccountRef(id: id, summary: Self.subscriptionSummary(match))
    }

    private static func subscriptionSummary(_ account: [String: Any]) -> String {
        let provider = sanitizeForTerminal((account["provider"] as? String) ?? "?")
        let label = (account["label"] as? String).map(sanitizeForTerminal) ?? ""
        return "\(provider)\(label.isEmpty ? "" : " \(label)")"
    }

    private func printSubscriptionAccounts(_ response: [String: Any]) {
        let accounts = (response["accounts"] as? [[String: Any]]) ?? []
        guard !accounts.isEmpty else {
            print("Subscription accounts: none. Codex on Cloud machines needs one:")
            print("  cmux coderouter subscriptions add codex")
            return
        }
        print("Subscription accounts (\(accounts.count)):")
        for account in accounts {
            let id = Self.sanitizeForTerminal((account["id"] as? String) ?? "?")
            var health = Self.sanitizeForTerminal((account["state"] as? String) ?? "?")
            if let cooldown = account["cooldownUntil"] as? String, !cooldown.isEmpty,
               let until = ISO8601DateFormatter.coderouterFlexible.date(from: cooldown), until > Date() {
                health = "cooling down \(Int(until.timeIntervalSinceNow.rounded(.up)))s"
            }
            if let code = (account["lastFailureCode"] as? String).map(Self.sanitizeForTerminal), !code.isEmpty {
                health += ", \(code)"
            }
            let sessions = Self.intValue(account["activeSessions"]) ?? 0
            var usageText = ""
            if let usage = account["usage"] as? [String: Any], let rate = usage["rate_limit"] as? [String: Any] {
                var windows: [String] = []
                if let primary = rate["primary_window"] as? [String: Any], let used = Self.doubleValue(primary["used_percent"]) {
                    windows.append("5h \(Int(used.rounded()))%")
                }
                if let secondary = rate["secondary_window"] as? [String: Any], let used = Self.doubleValue(secondary["used_percent"]) {
                    windows.append("week \(Int(used.rounded()))%")
                }
                if !windows.isEmpty { usageText = "  used " + windows.joined(separator: " / ") }
            } else if let error = (account["usageError"] as? String).map(Self.sanitizeForTerminal), !error.isEmpty {
                usageText = "  usage unavailable (\(error))"
            }
            print("  \(id)  \(Self.subscriptionSummary(account))  \(health)  sessions=\(sessions)\(usageText)")
        }
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
