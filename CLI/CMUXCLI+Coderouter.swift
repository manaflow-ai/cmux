import Darwin
import Foundation

// `cmux coderouter <status|machines|claude>`: the team-level settings of the
// cmux coderouter model plane that Cloud machines route their agents through.
// The CLI is presentation only; each verb maps to one `coderouter.*` socket
// method handled by the app's `CoderouterClient`, which holds the Stack
// session. Every other `cmux coderouter ...` verb, and all of `cmux cr ...`,
// is exec'd into the installed CodeRouter CLI before any socket is opened.
extension CMUXCLI {
    static let coderouterUsage = CMUXDiffViewerLocalization.string(
        "cli.coderouter.usage",
        defaultValue: """
        Usage: cmux coderouter <accounts|machines> [options]

        The accounts a team routes its Cloud machines through: ChatGPT Codex and
        OpenCode Go subscriptions, Claude Code OAuth tokens, Anthropic API keys,
        Amazon Bedrock credentials. Any other verb, and every `cmux cr ...`, runs
        the installed CodeRouter CLI unchanged.

          cmux coderouter accounts [--team <id>] [--json]
              Every account with kind, label, masked identifier, state, usage.

          cmux coderouter accounts add [claude|codex|opencode|anthropic-key|bedrock] [options]
              Add one account. Without a kind, cmux infers it from
              CLAUDE_CODE_OAUTH_TOKEN, ANTHROPIC_API_KEY, or a pasted secret,
              and asks in a terminal otherwise. Secrets come from the environment,
              --stdin, or a hidden prompt, never from argv.
              The credential is checked against its provider before it is
              stored (--no-validate skips that); the same secret twice is a no-op.
              claude: in a terminal cmux runs `claude setup-token` for you and
              keeps the token it prints; only setup-token tokens are accepted.
              claude and anthropic-key: --label, --stdin, --no-validate, --team, --json.
              bedrock: the same options, plus --region and --model; this kind must
              be explicit and reads AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY.
              codex and opencode accept no options and hand off to CodeRouter sign-in.

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
          cmux coderouter accounts add claude --label work
          cmux coderouter accounts
          cmux coderouter accounts remove work
        """
    )

    /// The first-argument verbs cmux owns under `cmux coderouter`. Everything
    /// else keeps the pre-existing passthrough into the installed CodeRouter CLI,
    /// so `cmux coderouter accounts`, `cmux coderouter login`, and a bare
    /// `cmux coderouter` behave exactly as before.
    static let cmuxOwnedCoderouterVerbs: Set<String> = ["accounts", "status", "machines", "claude", "subscriptions", "subs", "help", "--help", "-h"]

    static func isCmuxOwnedCoderouterInvocation(_ args: [String]) -> Bool {
        guard let first = args.first?.lowercased() else { return false }
        return cmuxOwnedCoderouterVerbs.contains(first)
    }

    func runCoderouterCommand(commandArgs: [String], client: SocketClient, jsonOutput: Bool) async throws {
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
                print(Self.coderouterLocalized("cli.coderouter.auth.notSignedIn", "Not signed in. Run `cmux auth login`, then retry."))
                return
            }
            let user = auth["user"] as? [String: Any]
            let email = (user?["email"] as? String).map(Self.sanitizeForTerminal) ?? "unknown account"
            print(Self.coderouterFormatted("cli.coderouter.auth.signedInAs", "Signed in as %@", email))
            let teamID = (accountsResponse?["teamId"] as? String) ?? (auth["selected_team_id"] as? String)
            if let teamID, !teamID.isEmpty {
                print(Self.coderouterFormatted("cli.coderouter.auth.team", "Team: %@", Self.sanitizeForTerminal(teamID)))
            }
            if let accountsError {
                print(Self.coderouterFormatted("cli.coderouter.auth.claudeUnavailable", "Claude upstream accounts: unavailable (%@)", accountsError))
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

        case "accounts":
            try await runCoderouterAccountsCommand(commandArgs: rest, client: client, jsonOutput: jsonOutput)

        case "claude":
            try await runCoderouterClaudeCommand(commandArgs: rest, client: client, jsonOutput: jsonOutput)

        case "subscriptions", "subs":
            try runCoderouterSubscriptionsCommand(commandArgs: rest, client: client, jsonOutput: jsonOutput)

        default:
            throw CLIError(message: """
                Unknown coderouter subcommand: \(Self.sanitizeForTerminal(sub))

                \(Self.coderouterUsage)
                """)
        }
    }

    private func runCoderouterClaudeCommand(commandArgs: [String], client: SocketClient, jsonOutput: Bool) async throws {
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
            try await runCoderouterClaudeAdd(commandArgs: rest, client: client, jsonOutput: jsonOutput)

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
                print(Self.coderouterFormatted("cli.coderouter.account.removed", "OK removed %@", account.summary))
            } else {
                print(Self.coderouterFormatted("cli.coderouter.account.removeMissing", "No Claude upstream account %@ exists.", account.summary))
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
            let state = sub == "disable"
                ? Self.coderouterLocalized("cli.coderouter.account.disabled", "disabled")
                : Self.coderouterLocalized("cli.coderouter.account.enabled", "enabled")
            print(Self.coderouterFormatted("cli.coderouter.account.stateChanged", "OK %@ %@", state, account.summary))

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
                print(Self.coderouterFormatted(
                    count == 1 ? "cli.coderouter.account.clearOne" : "cli.coderouter.account.clearMany",
                    count == 1
                        ? "OK removed %lld Claude upstream account. Cloud machines have no `claude` route until a new one is added."
                        : "OK removed %lld Claude upstream accounts. Cloud machines have no `claude` route until a new one is added.",
                    Int64(count)
                ))
            } else {
                print(Self.coderouterLocalized("cli.coderouter.account.clearEmpty", "No Claude upstream accounts were set."))
            }

        default:
            throw CLIError(message: """
                Unknown coderouter claude subcommand: \(Self.sanitizeForTerminal(sub))

                \(Self.coderouterUsage)
                """)
        }
    }

    private func runCoderouterClaudeAdd(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        secretOverride: String? = nil
    ) async throws {
        guard let kindArg = commandArgs.first, !Self.isCoderouterFlagToken(kindArg) else {
            throw CLIError(message: """
                coderouter claude add requires a credential kind: oauth-token, api-key, or bedrock.

                \(Self.coderouterUsage)
                """)
        }
        let rest = Array(commandArgs.dropFirst())
        let (teamOpt, rem0) = parseOption(rest, name: "--team")
        let (labelOpt, remLabel) = parseOption(rem0, name: "--label")
        let skipValidation = remLabel.contains("--no-validate")
        let rem1 = remLabel.filter { $0 != "--no-validate" }
        var params: [String: Any] = teamParams(teamOpt)
        if let label = Self.nonEmpty(labelOpt) {
            params["label"] = label
        }
        if skipValidation {
            params["validate"] = false
        }

        switch kindArg.lowercased() {
        case "oauth-token", "oauth", "claude-code":
            let forceStdin = rem1.contains("--stdin")
            try rejectUnexpectedCoderouterArguments(rem1.filter { $0 != "--stdin" }, command: "coderouter claude add oauth-token")
            let token = try await readClaudeSetupToken(forceStdin: forceStdin, override: secretOverride)
            guard token.hasPrefix("sk-ant-oat01-") else {
            throw CLIError(message: Self.coderouterLocalized("cli.coderouter.add.invalidOAuth", "That is not a Claude Code OAuth token (expected sk-ant-oat01-...). For an Anthropic API key use `cmux coderouter claude add api-key`."))
            }
            params["kind"] = "anthropic_oauth"
            params["token"] = token

        case "api-key", "apikey", "anthropic-key":
            let forceStdin = rem1.contains("--stdin")
            try rejectUnexpectedCoderouterArguments(rem1.filter { $0 != "--stdin" }, command: "coderouter claude add api-key")
            let apiKey = try readCoderouterSecret(
                label: Self.coderouterLocalized("cli.coderouter.secret.apiKeyLabel", "Anthropic API key"),
                envVar: "ANTHROPIC_API_KEY",
                forceStdin: forceStdin,
                hint: Self.coderouterLocalized("cli.coderouter.secret.apiKeyHint", "Create one in the Anthropic console."),
                override: secretOverride
            )
            guard apiKey.hasPrefix("sk-ant-"), !apiKey.hasPrefix("sk-ant-oat") else {
            throw CLIError(message: Self.coderouterLocalized("cli.coderouter.add.invalidApiKey", "That is not an Anthropic API key (expected sk-ant-...). For a Claude Code OAuth token use `cmux coderouter claude add oauth-token`."))
            }
            params["kind"] = "anthropic_api_key"
            params["apiKey"] = apiKey

        case "bedrock":
            let (regionOpt, rem2) = parseOption(rem1, name: "--region")
            var modelIDs: [String: String] = [:]
            var remaining = rem2
            while let index = remaining.firstIndex(of: "--model") {
                guard index + 1 < remaining.count else {
                    throw CLIError(message: Self.coderouterLocalized("cli.coderouter.add.bedrock.modelRequired", "coderouter claude add bedrock: --model requires <claude-model-id>=<bedrock-model-id>."))
                }
                let pair = remaining[index + 1]
                guard let equals = pair.firstIndex(of: "="), equals > pair.startIndex, pair.index(after: equals) < pair.endIndex else {
                    throw CLIError(message: Self.coderouterFormatted("cli.coderouter.add.bedrock.modelInvalid", "coderouter claude add bedrock: --model expects <claude-model-id>=<bedrock-model-id>, got '%@'.", Self.sanitizeForTerminal(pair)))
                }
                modelIDs[String(pair[..<equals])] = String(pair[pair.index(after: equals)...])
                remaining.removeSubrange(index...(index + 1))
            }
            try rejectUnexpectedCoderouterArguments(remaining, command: "coderouter claude add bedrock")
            let env = ProcessInfo.processInfo.environment
            let region = Self.nonEmpty(regionOpt) ?? Self.nonEmpty(env["AWS_REGION"]) ?? Self.nonEmpty(env["AWS_DEFAULT_REGION"])
            guard let region else {
                throw CLIError(message: Self.coderouterLocalized("cli.coderouter.add.bedrock.regionRequired", "coderouter claude add bedrock requires --region <r> or AWS_REGION / AWS_DEFAULT_REGION."))
            }
            guard let accessKeyID = Self.nonEmpty(env["AWS_ACCESS_KEY_ID"]),
                  let secretAccessKey = Self.nonEmpty(env["AWS_SECRET_ACCESS_KEY"]) else {
                throw CLIError(message: Self.coderouterLocalized("cli.coderouter.add.bedrock.credentialsRequired", "coderouter claude add bedrock reads AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY from your shell environment; export both, then retry."))
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
            throw CLIError(message: Self.coderouterFormatted("cli.coderouter.add.unsupportedKind", "coderouter claude add: unsupported credential kind '%@'. Use oauth-token, api-key, or bedrock.", Self.sanitizeForTerminal(kindArg)))
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
        let summary = "\(kind)\(identifier.isEmpty ? "" : " \(identifier)")\(label.isEmpty ? "" : " (\(label))")"
        if (response["alreadyExists"] as? Bool) == true {
            print(Self.coderouterFormatted("cli.coderouter.add.alreadyAdded", "Already added: %@ is on this team, nothing changed.", summary))
            if let id = (account?["id"] as? String).map(Self.sanitizeForTerminal), !id.isEmpty {
                print(Self.coderouterFormatted("cli.coderouter.add.id", "  id: %@", id))
            }
            return
        }
        let validation = (response["validation"] as? String) ?? ""
        let verified = validation == "ok"
            ? Self.coderouterLocalized("cli.coderouter.add.verified", " (verified with the provider)")
            : validation == "unreachable"
                ? Self.coderouterLocalized("cli.coderouter.add.unreachable", " (provider unreachable, stored unverified)")
                : ""
        print(Self.coderouterFormatted("cli.coderouter.add.success", "OK added Claude upstream account: %@%@", summary, verified))
        if let id = (account?["id"] as? String).map(Self.sanitizeForTerminal), !id.isEmpty {
            print(Self.coderouterFormatted("cli.coderouter.add.id", "  id: %@", id))
        }
        if let teamID = (response["teamId"] as? String).map(Self.sanitizeForTerminal), !teamID.isEmpty {
            print(Self.coderouterFormatted("cli.coderouter.add.team", "  team: %@", teamID))
        }
        if let region = (account?["region"] as? String).map(Self.sanitizeForTerminal), !region.isEmpty {
            print(Self.coderouterFormatted("cli.coderouter.add.region", "  region: %@", region))
        }
        if let total = Self.intValue(response["accountsTotal"]) {
            print(Self.coderouterFormatted(
                "cli.coderouter.add.routeCount",
                "Cloud machines now route `claude` across %lld account%@.",
                Int64(total),
                total == 1 ? "" : "s"
            ))
        }
    }

    /// Claude Code tokens: environment, stdin, or, in a terminal, run
    /// `claude setup-token` on the user's behalf and keep the token it prints
    /// (the browser sign-in happens inside that command). Only setup-token
    /// tokens are accepted; cmux never runs an OAuth flow of its own.
    private func readClaudeSetupToken(forceStdin: Bool, override: String? = nil) async throws -> String {
        if let override = Self.nonEmpty(override) {
            return override
        }
        let env = ProcessInfo.processInfo.environment
        if !forceStdin, let fromEnv = Self.nonEmpty(env["CLAUDE_CODE_OAUTH_TOKEN"]) {
            return fromEnv
        }
        if forceStdin || isatty(STDIN_FILENO) == 0 {
            return try readCoderouterSecret(
                label: Self.coderouterLocalized("cli.coderouter.secret.oauthLabel", "Claude Code OAuth token"),
                envVar: "CLAUDE_CODE_OAUTH_TOKEN",
                forceStdin: forceStdin,
                hint: Self.coderouterLocalized("cli.coderouter.secret.oauthHint", "Run `claude setup-token` to mint one.")
            )
        }
        if let claude = resolveExecutableInPath("claude") {
            let message = Self.coderouterLocalized(
                "cli.coderouter.setup.running",
                "Running `claude setup-token` to mint a long-lived token; finish the sign-in in your browser.\n"
            )
            FileHandle.standardError.write(Data(message.utf8))
            if let token = await runClaudeSetupToken(executable: claude) {
                return token
            }
            let fallback = Self.coderouterLocalized(
                "cli.coderouter.setup.noToken",
                "`claude setup-token` did not print a token; paste one instead.\n"
            )
            FileHandle.standardError.write(Data(fallback.utf8))
        }
        return try readHiddenTerminalLine(prompt: Self.coderouterLocalized(
            "cli.coderouter.setup.prompt",
            "Claude Code OAuth token (input hidden; run `claude setup-token` to mint one): "
        ))
    }

    /// Runs `claude setup-token` with the terminal attached for its prompts and
    /// browser hand-off, capturing stdout to pick the token out of it.
    private func runClaudeSetupToken(executable: String) async -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["setup-token"]
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key.hasPrefix("CMUX_") || key.hasPrefix("CLAUDE_CODE_") {
            environment.removeValue(forKey: key)
        }
        process.environment = environment
        process.standardInput = FileHandle.standardInput
        let pipe = Pipe()
        process.standardOutput = pipe
        // Claude has printed the token on stderr in some CLI versions. Route
        // both streams through the same line-buffered redactor so a token can
        // never reach the terminal, even when its marker is split across pipe
        // chunks.
        process.standardError = pipe
        let reader = pipe.fileHandleForReading
        let termination = AsyncStream<Int32> { continuation in
            process.terminationHandler = { process in
                continuation.yield(process.terminationStatus)
                continuation.finish()
            }
            continuation.onTermination = { _ in
                process.terminationHandler = nil
            }
        }
        do {
            try process.run()
        } catch {
            reader.readabilityHandler = nil
            return nil
        }

        // `readabilityHandler` runs on the system's pipe callback queue, so
        // this async stream drains the child without parking a cooperative
        // thread. The consumer owns the capture and redactor; no shared
        // mutable buffer or cancellation race is needed.
        var capture = Data()
        var redactor = ClaudeSetupTokenEchoRedactor()
        for await chunk in ClaudeSetupTokenPipe.chunks(from: reader) {
            capture.append(chunk)
            for line in redactor.feed(chunk) {
                FileHandle.standardError.write(line)
            }
        }
        let tail = redactor.finish()
        if !tail.isEmpty { FileHandle.standardError.write(tail) }
        var terminatedStatus: Int32?
        for await status in termination {
            terminatedStatus = status
            break
        }
        let status = terminatedStatus ?? process.terminationStatus
        let output = String(decoding: capture, as: UTF8.self)
        guard status == 0 else { return nil }
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        guard let regex = try? NSRegularExpression(pattern: "sk-ant-oat01-[A-Za-z0-9_-]{20,}"),
              let match = regex.firstMatch(in: output, range: range),
              let tokenRange = Range(match.range, in: output) else { return nil }
        return String(output[tokenRange])
    }

    /// Holds output until a newline so a token split across `Pipe` chunks is
    /// redacted as one value. The raw bytes remain in the capture only for
    /// token extraction and are never written to stderr.
    private struct ClaudeSetupTokenEchoRedactor {
        private var pending = Data()

        mutating func feed(_ chunk: Data) -> [Data] {
            pending.append(chunk)
            var lines: [Data] = []
            while let newline = pending.firstIndex(of: 0x0a) {
                let end = pending.index(after: newline)
                lines.append(Self.redact(pending.subdata(in: pending.startIndex..<end)))
                pending.removeSubrange(pending.startIndex..<end)
            }
            return lines
        }

        mutating func finish() -> Data {
            guard !pending.isEmpty else { return Data() }
            let tail = Self.redact(pending)
            pending.removeAll(keepingCapacity: false)
            return tail
        }

        private static func redact(_ data: Data) -> Data {
            let text = String(decoding: data, as: UTF8.self)
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let regex = try? NSRegularExpression(pattern: "sk-ant-oat01-[A-Za-z0-9_-]{1,}") else {
                return data
            }
            let redacted = regex.stringByReplacingMatches(
                in: text,
                range: range,
                withTemplate: "[setup token redacted]"
            )
            return Data(redacted.utf8)
        }
    }

    private enum ClaudeSetupTokenPipe {
        /// Convert a child-process pipe into an async stream. FileHandle calls
        /// the readability handler on its own dispatch source, while the
        /// caller consumes bytes with async iteration.
        static func chunks(from handle: FileHandle) -> AsyncStream<Data> {
            AsyncStream(bufferingPolicy: .unbounded) { continuation in
                handle.readabilityHandler = { fileHandle in
                    let data = fileHandle.availableData
                    if data.isEmpty {
                        fileHandle.readabilityHandler = nil
                        continuation.finish()
                    } else {
                        continuation.yield(data)
                    }
                }
                continuation.onTermination = { _ in
                    handle.readabilityHandler = nil
                }
            }
        }
    }

    /// Secret intake order: `--stdin` (or a non-TTY stdin) reads one line from
    /// stdin; otherwise the named environment variable; otherwise a hidden
    /// terminal prompt. Argv is deliberately not an option: it leaks into shell
    /// history and process listings.
    private func readCoderouterSecret(
        label: String,
        envVar: String,
        forceStdin: Bool,
        hint: String,
        override: String? = nil
    ) throws -> String {
        if let override = Self.nonEmpty(override) {
            return override
        }
        let stdinIsTerminal = isatty(STDIN_FILENO) == 1
        if forceStdin || !stdinIsTerminal {
            if !forceStdin, let fromEnv = Self.nonEmpty(ProcessInfo.processInfo.environment[envVar]) {
                return fromEnv
            }
            let data = FileHandle.standardInput.readDataToEndOfFile()
            let text = String(decoding: data, as: UTF8.self)
            guard let line = text.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) else {
                throw CLIError(message: Self.coderouterFormatted("cli.coderouter.secret.noStdin", "No %@ on stdin. %@", label, hint))
            }
            return line
        }
        if let fromEnv = Self.nonEmpty(ProcessInfo.processInfo.environment[envVar]) {
            return fromEnv
        }
        let hintText = hint.lowercased().hasSuffix(".") ? String(hint.dropLast()) : hint
        return try readHiddenTerminalLine(prompt: Self.coderouterFormatted(
            "cli.coderouter.secret.prompt",
            "%@ (input hidden; %@): ",
            label,
            hintText
        ))
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
            throw CLIError(message: Self.coderouterLocalized("cli.coderouter.input.none", "No input received."))
        }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CLIError(message: Self.coderouterLocalized("cli.coderouter.input.none", "No input received."))
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
            case .claude:
                return CMUXDiffViewerLocalization.string(
                    "cli.coderouter.picker.claude",
                    defaultValue: "Claude Code token (cmux runs `claude setup-token` for you)"
                )
            case .codex:
                return CMUXDiffViewerLocalization.string(
                    "cli.coderouter.picker.codex",
                    defaultValue: "ChatGPT Codex subscription (signs in through the CodeRouter CLI)"
                )
            case .opencode:
                return CMUXDiffViewerLocalization.string(
                    "cli.coderouter.picker.opencode",
                    defaultValue: "OpenCode Go subscription (signs in through the CodeRouter CLI)"
                )
            case .anthropicKey:
                return CMUXDiffViewerLocalization.string(
                    "cli.coderouter.picker.anthropicKey",
                    defaultValue: "Anthropic API key"
                )
            case .bedrock:
                return CMUXDiffViewerLocalization.string(
                    "cli.coderouter.picker.bedrock",
                    defaultValue: "Amazon Bedrock credentials (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY)"
                )
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
            let safeKind = CMUXCLI.sanitizeForTerminal(kind)
            let safeIdentifier = CMUXCLI.sanitizeForTerminal(identifier)
            let safeLabel = CMUXCLI.sanitizeForTerminal(label)
            return "\(safeKind) \(identifier.isEmpty ? safeLabel : safeIdentifier)\(identifier.isEmpty || label.isEmpty ? "" : " (\(safeLabel))")"
        }
    }

    func runCoderouterAccountsCommand(commandArgs: [String], client: SocketClient, jsonOutput: Bool) async throws {
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
            try await runCoderouterAccountsAdd(commandArgs: rest, client: client, jsonOutput: jsonOutput)

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
                throw CLIError(message: Self.coderouterFormatted(
                    "cli.coderouter.account.subscriptionPause",
                    "%@ is a subscription; subscriptions cannot be paused. Remove it with `cmux coderouter accounts remove` instead.",
                    account.summary
                ))
            }
            var params = teamParams(teamOpt)
            params["accountId"] = account.id
            params["state"] = paused ? "disabled" : "active"
            let response = try client.sendV2(method: "coderouter.claude_upstream.update", params: params)
            if jsonOutput {
                print(jsonString(response))
                return
            }
            let state = paused
                ? Self.coderouterLocalized("cli.coderouter.account.paused", "paused")
                : Self.coderouterLocalized("cli.coderouter.account.resumed", "resumed")
            print(Self.coderouterFormatted("cli.coderouter.account.pauseState", "OK %@ %@", state, account.summary))

        default:
            // `cmux coderouter accounts <label>` is a common slip; point at the verbs.
            throw CLIError(message: """
                Unknown coderouter accounts subcommand: \(Self.sanitizeForTerminal(sub))

                \(Self.coderouterUsage)
                """)
        }
    }

    private func runCoderouterAccountsAdd(commandArgs: [String], client: SocketClient, jsonOutput: Bool) async throws {
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
                throw CLIError(message: Self.coderouterFormatted(
                    "cli.coderouter.add.unknownKind",
                    "Unknown account kind '%@'. Use claude, codex, opencode, anthropic-key, or bedrock.",
                    Self.sanitizeForTerminal(kindArg)
                ))
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
            } else if forceStdin || isatty(STDIN_FILENO) == 0 {
                let secret = try readCoderouterSecret(
                    label: Self.coderouterLocalized("cli.coderouter.secret.credentialLabel", "credential"),
                    envVar: "CMUX_CODEROUTER_UNSET",
                    forceStdin: true,
                    hint: Self.coderouterLocalized("cli.coderouter.secret.credentialHint", "Paste a Claude Code OAuth token or an Anthropic API key.")
                )
                guard let inferred = Self.inferKind(fromSecret: secret) else {
                    throw CLIError(message: Self.coderouterLocalized(
                        "cli.coderouter.add.unknownSecret",
                        "Could not tell what that secret is. Pass the kind: cmux coderouter accounts add <claude|anthropic-key|bedrock|codex|opencode>."
                    ))
                }
                kind = inferred
                pastedSecret = secret
            } else {
                kind = try pickCoderouterAccountKind()
            }
        }
        let resolved = kind!
        var forwarded = args.filter { $0 != "--stdin" }
        if pastedSecret == nil, forceStdin {
            forwarded.append("--stdin")
        }
        switch resolved {
        case .claude:
            try await runCoderouterClaudeAdd(
                commandArgs: ["oauth-token"] + forwarded,
                client: client,
                jsonOutput: jsonOutput,
                secretOverride: pastedSecret
            )
        case .anthropicKey:
            try await runCoderouterClaudeAdd(
                commandArgs: ["api-key"] + forwarded,
                client: client,
                jsonOutput: jsonOutput,
                secretOverride: pastedSecret
            )
        case .bedrock:
            try await runCoderouterClaudeAdd(commandArgs: ["bedrock"] + forwarded, client: client, jsonOutput: jsonOutput)
        case .codex, .opencode:
            if jsonOutput {
                throw CLIError(message: Self.coderouterFormatted(
                    "cli.coderouter.add.subscriptionJSON",
                    "coderouter accounts add %@ cannot use --json because the CodeRouter CLI owns the sign-in flow.",
                    resolved.rawValue
                ))
            }
            if let unsupported = forwarded.first(where: {
                $0 == "--team" || $0.hasPrefix("--team=")
                    || $0 == "--label" || $0.hasPrefix("--label=")
                    || $0 == "--no-validate" || $0 == "--stdin"
            }) {
                throw CLIError(message: Self.coderouterFormatted(
                    "cli.coderouter.add.subscriptionOption",
                    "coderouter accounts add %@ does not support %@; run `cmux coderouter subscriptions add %@` with no account options.",
                    resolved.rawValue,
                    Self.sanitizeForTerminal(unsupported),
                    resolved.rawValue
                ))
            }
            try rejectUnexpectedCoderouterArguments(forwarded, command: "coderouter accounts add \(resolved.rawValue)")
            try runCoderouterSubscriptionsCommand(commandArgs: ["add", resolved.rawValue], client: client, jsonOutput: jsonOutput)
        }
    }

    private static func inferKind(fromSecret secret: String) -> CoderouterAccountKind? {
        if secret.hasPrefix("sk-ant-oat01-") { return .claude }
        if secret.hasPrefix("sk-ant-") { return .anthropicKey }
        return nil
    }

    /// Numbered menu on stderr; stdout stays clean for scripts.
    private func pickCoderouterAccountKind() throws -> CoderouterAccountKind {
        let kinds = CoderouterAccountKind.allCases
        var menu = Self.coderouterLocalized("cli.coderouter.picker.title", "Add which account?\n")
        for (index, kind) in kinds.enumerated() {
            menu += Self.coderouterFormatted("cli.coderouter.picker.item", "  %lld) %@\n", Int64(index + 1), kind.pickerLine)
        }
        menu += Self.coderouterLocalized("cli.coderouter.picker.choice", "Choice [1]: ")
        FileHandle.standardError.write(Data(menu.utf8))
        guard let line = readLine(strippingNewline: true) else {
            throw CLIError(message: Self.coderouterLocalized("cli.coderouter.picker.noChoice", "No choice received."))
        }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return kinds[0] }
        if let number = Int(trimmed), (1...kinds.count).contains(number) { return kinds[number - 1] }
        if let named = CoderouterAccountKind.parse(trimmed) { return named }
        throw CLIError(message: Self.coderouterFormatted(
            "cli.coderouter.picker.invalidChoice",
            "'%@' is not a choice. Use 1-%lld or a kind name.",
            Self.sanitizeForTerminal(trimmed),
            Int64(kinds.count)
        ))
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
            accounts.append(UnifiedAccount(source: .claude, id: id, kind: kind, label: (account["label"] as? String) ?? "", identifier: (account["identifier"] as? String) ?? "", health: Self.claudeAccountHealth(account), usage: (account["state"] as? String) == "broken" ? "replace it: cmux coderouter accounts add" : ((account["region"] as? String) ?? ""), raw: account))
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
            print(Self.coderouterLocalized("cli.coderouter.accounts.empty", "No accounts. Cloud machines cannot run codex or claude until one is added:"))
            print(Self.coderouterLocalized("cli.coderouter.accounts.emptyCommand", "  cmux coderouter accounts add"))
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
                throw CLIError(message: Self.coderouterFormatted(
                    "cli.coderouter.accounts.noMatch",
                    "No account matches '%@'. Run `cmux coderouter accounts` and use the id, label, or identifier.",
                    Self.sanitizeForTerminal(selector)
                ))
            }
            throw CLIError(message: Self.coderouterFormatted(
                "cli.coderouter.accounts.ambiguous",
                "'%@' matches %lld accounts. Use more of the id from `cmux coderouter accounts`.",
                Self.sanitizeForTerminal(selector),
                Int64(matches.count)
            ))
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
            if jsonOutput {
                throw CLIError(message: Self.coderouterLocalized(
                    "cli.coderouter.subscriptions.addJSON",
                    "coderouter subscriptions add cannot use --json because the CodeRouter CLI owns the sign-in flow."
                ))
            }
            if let flag = rest.first(where: Self.isCoderouterFlagToken) {
                throw CLIError(message: Self.coderouterFormatted(
                    "cli.coderouter.subscriptions.addFlag",
                    "coderouter subscriptions add does not support %@; run it with only an optional provider name.",
                    Self.sanitizeForTerminal(flag)
                ))
            }
            let provider = rest.first?.lowercased() ?? "codex"
            guard rest.count <= 1, ["codex", "opencode"].contains(provider) else {
                throw CLIError(message: Self.coderouterLocalized(
                    "cli.coderouter.subscriptions.addUsage",
                    "coderouter subscriptions add takes an optional provider: codex (default) or opencode."
                ))
            }
            do {
                try runCoderouterAlias(commandArgs: ["add", provider])
            } catch let error as CLIError where error.exitCode == 127 {
                throw CLIError(
                    message: Self.coderouterFormatted(
                        "cli.coderouter.subscriptions.cliMissing",
                        "The CodeRouter CLI is not installed. Add the subscription with:\n  npx coderouter@latest add %@\nThen run `cmux coderouter subscriptions list`.",
                        provider
                    ),
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
                print(Self.coderouterFormatted("cli.coderouter.subscription.removed", "OK removed %@", account.summary))
                if (response["lastAccount"] as? Bool) == true {
                    print(Self.coderouterLocalized(
                        "cli.coderouter.subscription.lastRemoved",
                        "That was the last subscription: Codex sessions from Cloud machines fail until one is added."
                    ))
                }
            } else {
                print(Self.coderouterFormatted("cli.coderouter.subscription.removeMissing", "No subscription account %@ exists.", account.summary))
            }

        default:
            throw CLIError(message: """
                Unknown coderouter subscriptions subcommand: \(Self.sanitizeForTerminal(sub))

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
                throw CLIError(message: Self.coderouterFormatted(
                    "cli.coderouter.subscription.noMatch",
                    "No subscription account matches '%@'. Run `cmux coderouter subscriptions list` and use the id, label, or provider account id.",
                    Self.sanitizeForTerminal(selector)
                ))
            }
            throw CLIError(message: Self.coderouterFormatted(
                "cli.coderouter.subscription.ambiguous",
                "'%@' matches %lld subscription accounts. Use the id from `cmux coderouter subscriptions list`.",
                Self.sanitizeForTerminal(selector),
                Int64(matches.count)
            ))
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
            print(Self.coderouterLocalized("cli.coderouter.subscriptions.empty", "Subscription accounts: none. Codex on Cloud machines needs one:"))
            print(Self.coderouterLocalized("cli.coderouter.subscriptions.emptyCommand", "  cmux coderouter subscriptions add codex"))
            return
        }
        print(Self.coderouterFormatted("cli.coderouter.subscriptions.count", "Subscription accounts (%lld):", Int64(accounts.count)))
        for account in accounts {
            let id = Self.sanitizeForTerminal((account["id"] as? String) ?? "?")
            var health = Self.sanitizeForTerminal((account["state"] as? String) ?? "?")
            if let cooldown = account["cooldownUntil"] as? String, !cooldown.isEmpty,
               let until = ISO8601DateFormatter.coderouterFlexible.date(from: cooldown), until > Date() {
                health = Self.coderouterFormatted(
                    "cli.coderouter.health.coolingDown",
                    "cooling down %llds",
                    Int64(until.timeIntervalSinceNow.rounded(.up))
                )
            }
            if let code = (account["lastFailureCode"] as? String).map(Self.sanitizeForTerminal), !code.isEmpty {
                health += Self.coderouterFormatted("cli.coderouter.health.failureCodeWithComma", ", %@", code)
            }
            let sessions = Self.intValue(account["activeSessions"]) ?? 0
            var usageText = ""
            if let usage = account["usage"] as? [String: Any], let rate = usage["rate_limit"] as? [String: Any] {
                var windows: [String] = []
                if let primary = rate["primary_window"] as? [String: Any], let used = Self.doubleValue(primary["used_percent"]) {
                    windows.append(Self.coderouterFormatted("cli.coderouter.usage.fiveHour", "5h %lld%%", Int64(used.rounded())))
                }
                if let secondary = rate["secondary_window"] as? [String: Any], let used = Self.doubleValue(secondary["used_percent"]) {
                    windows.append(Self.coderouterFormatted("cli.coderouter.usage.week", "week %lld%%", Int64(used.rounded())))
                }
                if !windows.isEmpty {
                    usageText = Self.coderouterFormatted("cli.coderouter.usage.used", "  used %@", windows.joined(separator: " / "))
                }
            } else if let error = (account["usageError"] as? String).map(Self.sanitizeForTerminal), !error.isEmpty {
                usageText = Self.coderouterFormatted("cli.coderouter.usage.unavailable", "  usage unavailable (%@)", error)
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
                throw CLIError(message: Self.coderouterFormatted(
                    "cli.coderouter.claude.noMatch",
                    "No Claude upstream account matches '%@'. Run `cmux coderouter claude list` and use the id, label, or identifier.",
                    Self.sanitizeForTerminal(selector)
                ))
            }
            throw CLIError(message: Self.coderouterFormatted(
                "cli.coderouter.claude.ambiguous",
                "'%@' matches %lld Claude upstream accounts. Use the id from `cmux coderouter claude list`.",
                Self.sanitizeForTerminal(selector),
                Int64(matches.count)
            ))
        }
        return ClaudeAccountRef(id: id, summary: Self.claudeAccountSummary(match))
    }

    private func singleCoderouterSelector(_ args: [String], command: String) throws -> String {
        if let unknown = args.first(where: Self.isCoderouterFlagToken) {
            throw CLIError(message: Self.coderouterFormatted(
                "cli.coderouter.error.unknownFlag",
                "%@: unknown flag '%@'.\n\n%@",
                command,
                Self.sanitizeForTerminal(unknown),
                Self.coderouterUsage
            ))
        }
        guard let selector = args.first, !selector.isEmpty else {
            throw CLIError(message: Self.coderouterFormatted(
                "cli.coderouter.error.selectorRequired",
                "%@ requires an account id, label, or identifier. Run `cmux coderouter claude list`.",
                command
            ))
        }
        if args.count > 1 {
            throw CLIError(message: Self.coderouterFormatted(
                "cli.coderouter.error.unexpectedArgument",
                "%@: unexpected argument '%@'.",
                command,
                Self.sanitizeForTerminal(args[1])
            ))
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
            print(Self.coderouterLocalized("cli.coderouter.claude.empty", "Claude upstream accounts: none. Cloud machines cannot run `claude` until one is added:"))
            print(Self.coderouterLocalized("cli.coderouter.claude.emptyCommand", "  cmux coderouter accounts add claude"))
            return
        }
        print(Self.coderouterFormatted("cli.coderouter.claude.count", "Claude upstream accounts (%lld):", Int64(accounts.count)))
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
            return CMUXDiffViewerLocalization.string("cli.coderouter.health.disabled", defaultValue: "disabled")
        }
        if (account["state"] as? String) == "broken" {
            let code = (account["lastFailureCode"] as? String).map(sanitizeForTerminal) ?? "rejected"
            return String.localizedStringWithFormat(
                CMUXDiffViewerLocalization.string("cli.coderouter.health.broken", defaultValue: "broken (%@)"),
                code
            )
        }
        var parts: [String] = []
        if let cooldown = (account["cooldownUntil"] as? String), !cooldown.isEmpty,
           let until = ISO8601DateFormatter.coderouterFlexible.date(from: cooldown), until > Date() {
            let seconds = Int(until.timeIntervalSinceNow.rounded(.up))
            parts.append(Self.coderouterFormatted("cli.coderouter.health.coolingDown", "cooling down %llds", Int64(seconds)))
            if let code = (account["lastFailureCode"] as? String).map(sanitizeForTerminal), !code.isEmpty {
                parts.append(Self.coderouterFormatted("cli.coderouter.health.failureCode", "%@", code))
            }
        } else {
            parts.append(CMUXDiffViewerLocalization.string("cli.coderouter.health.active", defaultValue: "active"))
        }
        if let lastUsed = (account["lastUsedAt"] as? String), !lastUsed.isEmpty {
            parts.append(Self.coderouterFormatted("cli.coderouter.health.lastUsed", "last used %@", sanitizeForTerminal(lastUsed)))
        }
        return parts.joined(separator: ", ")
    }

    private func printMachineUsage(_ response: [String: Any]) {
        let kind = (response["kind"] as? String) ?? "unavailable"
        guard kind == "ready" else {
            print(Self.coderouterLocalized(
                "cli.coderouter.machines.unavailable",
                "Machine usage is unavailable right now (the coderouter usage ledger did not answer). Retry in a moment."
            ))
            return
        }
        let machines = (response["machines"] as? [[String: Any]]) ?? []
        let periodDays = (response["periodDays"] as? Int) ?? 30
        guard !machines.isEmpty else {
            print(Self.coderouterFormatted(
                "cli.coderouter.machines.empty",
                "No coderouter usage from Cloud machines in the last %lld days.",
                Int64(periodDays)
            ))
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
        print(Self.coderouterFormatted(
            "cli.coderouter.machines.total",
            "Total (%lldd): %lld machine%@, tokens=%lld, %@ API-equivalent",
            Int64(periodDays),
            Int64(machines.count),
            machines.count == 1 ? "" : "s",
            Int64(totalTokens),
            Self.formatUSD(totalUSD)
        ))
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
            throw CLIError(message: Self.coderouterFormatted(
                "cli.coderouter.error.unknownFlag",
                "%@: unknown flag '%@'.\n\n%@",
                command,
                Self.sanitizeForTerminal(unknown),
                Self.coderouterUsage
            ))
        }
        if let extra = args.first {
            throw CLIError(message: Self.coderouterFormatted(
                "cli.coderouter.error.unexpectedArgument",
                "%@: unexpected argument '%@'.",
                command,
                Self.sanitizeForTerminal(extra)
            ))
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

    private static func coderouterLocalized(_ key: String, _ defaultValue: String) -> String {
        CMUXDiffViewerLocalization.string(key, defaultValue: defaultValue)
    }

    private static func coderouterFormatted(
        _ key: String,
        _ defaultValue: String,
        _ arguments: CVarArg...
    ) -> String {
        let format = coderouterLocalized(key, defaultValue)
        return String(format: format, locale: Locale.current, arguments: arguments)
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
