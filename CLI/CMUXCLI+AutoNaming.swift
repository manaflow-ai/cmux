import CMUXAgentLaunch
import Foundation

// Auto-naming engine: pure, dependency-injected logic for naming workspaces
// and tabs from agent conversation content. This file is compiled into both
// the bundled CLI target (which drives it from agent hooks) and the cmux-unit
// test target (the CLI is a tool target that tests cannot import), so it must
// not reference CLI-private symbols.

/// Tunable constants for the auto-naming engine. Defaults follow the
/// debounce shape proven by community prior art (manaflow-ai/cmux#2043)
/// and are expected to be tuned from dogfood feedback.
struct AutoNamingConfig: Sendable {
    /// Minimum transcript line growth since the last naming before another
    /// summarization call is considered.
    var minLineGrowth: Int = 6
    /// Minimum seconds between summarization calls for one session.
    var minInterval: TimeInterval = 180
    /// Transcripts shorter than this are skipped entirely (subagent or
    /// trivial sessions).
    var minTranscriptLines: Int = 12
    /// Hard deadline for the summarizer subprocess.
    var llmTimeout: TimeInterval = 60
    /// Extra slack on top of `llmTimeout` before an in-flight marker is
    /// considered stale: covers the termination grace window and the socket
    /// apply, so a pass still finishing cannot be doubled by a concurrent
    /// Stop, while a crashed pass cannot block naming forever.
    var inFlightExpiryGrace: TimeInterval = 15

    /// Total lifetime of an in-flight marker before a new pass may start.
    var inFlightExpiry: TimeInterval { llmTimeout + inFlightExpiryGrace }
    /// Maximum title length after sanitization.
    var maxTitleLength: Int = 50
    /// Leading user messages included in the summarization context.
    var contextHeadUserMessages: Int = 2
    /// Trailing user/assistant messages included in the context.
    var contextTailMessages: Int = 4
    /// Per-message truncation applied to context excerpts.
    var contextMessageMaxChars: Int = 240
}

/// Projection of one session's persisted auto-naming state, read from the
/// agent hook session store under its lock.
struct AutoNamingSessionSnapshot: Sendable {
    var lastTitle: String?
    var lastLineCount: Int?
    var lastNamedAt: TimeInterval?
    var inFlightAt: TimeInterval?
    /// True after the agent's native title command (for example Claude's
    /// `/rename`) establishes user ownership of the session title.
    var userOwned: Bool
    /// Last attempt time, success or failure (see the record field of the same
    /// purpose). Drives the failure cooldown in ``throttleDecision``.
    var lastAttemptAt: TimeInterval?

    init(
        lastTitle: String? = nil,
        lastLineCount: Int? = nil,
        lastNamedAt: TimeInterval? = nil,
        inFlightAt: TimeInterval? = nil,
        lastAttemptAt: TimeInterval? = nil,
        userOwned: Bool = false
    ) {
        self.lastTitle = lastTitle
        self.lastLineCount = lastLineCount
        self.lastNamedAt = lastNamedAt
        self.inFlightAt = inFlightAt
        self.lastAttemptAt = lastAttemptAt
        self.userOwned = userOwned
    }
}

/// Outcome of the throttle evaluation that gates a summarization call.
enum AutoNamingThrottleDecision: Equatable, Sendable {
    /// Run the summarizer; on success the baseline advances to this count.
    case proceed(baseline: Int)
    /// The transcript shrank (compaction or resume rewrite): record the new
    /// baseline without naming so future growth measures from it.
    case reseedBaseline(to: Int)
    case skipShortTranscript
    /// The agent or user explicitly owns the title, so summarization must stop.
    case skipUserOwned
    case skipInFlight
    case skipTooSoon
    case skipInsufficientGrowth
}

/// One user/assistant text message extracted from a transcript.
struct AutoNamingTranscriptMessage: Codable, Equatable, Sendable {
    var role: String
    var text: String
}

/// Environment policy for the summarizer subprocess: scrub the variables
/// that would recurse into cmux hooks or the parent agent session while
/// preserving backend selection (Vertex/Bedrock/Anthropic) so the call works
/// for users on any auth path.
struct AutoNamingEnvironmentPolicy: Sendable {
    /// Exact variables marking a live agent session or cmux terminal; never pass them to the summarizer.
    private static let scrubbedExactKeys = ClaudeSessionEnvironmentPolicy()
        .inheritedSessionIdentityKeys
        .union(["NODE_OPTIONS"])

    func summarizerEnvironment(from env: [String: String]) -> [String: String] {
        env.filter { key, _ in
            if key.hasPrefix("CMUX_") { return false }
            if Self.scrubbedExactKeys.contains(key) { return false }
            return true
        }
    }

    /// Minimal environment for tool-disabled Codex summarization. Keep auth
    /// discovery and proxy settings, but do not forward other agent/provider
    /// credentials into a process that receives untrusted transcript text.
    func codexSummarizerEnvironment(from env: [String: String]) -> [String: String] {
        let selected = summarizerEnvironment(from: env)
        let allowedExactKeys: Set<String> = [
            "HOME",
            "PATH",
            "TMPDIR",
            "TMP",
            "TEMP",
            "USER",
            "LOGNAME",
            "SHELL",
            "CODEX_HOME",
            "OPENAI_API_KEY",
            "OPENAI_BASE_URL",
            "OPENAI_ORG_ID",
            "OPENAI_ORGANIZATION",
            "SSL_CERT_FILE",
            "SSL_CERT_DIR",
            "HTTP_PROXY",
            "HTTPS_PROXY",
            "ALL_PROXY",
            "NO_PROXY"
        ]
        return selected.filter { key, _ in
            allowedExactKeys.contains(key)
        }
    }

    /// The model passed to `claude -p`. Honors the user's small/fast model
    /// override so Vertex/Bedrock deployments are not broken by a hardcoded
    /// Anthropic alias.
    func claudeModel(from env: [String: String]) -> String {
        let override = env["ANTHROPIC_SMALL_FAST_MODEL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return override.isEmpty ? "haiku" : override
    }

    /// Inline MCP configuration passed with `--strict-mcp-config` so the
    /// summarizer starts no MCP servers. Claude Code validates this JSON
    /// against a schema requiring an `mcpServers` record, so a bare `{}` is
    /// rejected during argument parsing and the subprocess exits before it
    /// can produce a title (cmux#9457).
    static let emptyMCPConfigJSON = #"{"mcpServers":{}}"#

    /// OpenCode's `--pure` switch disables external plugins, but its default
    /// agent still allows built-in tools. Deny every permission for the
    /// summarizer so transcript text cannot trigger file, shell, MCP, or web
    /// tools while the provider credentials remain available for the model
    /// request itself.
    static let openCodeDenyAllPermissionsJSON = #"{"*":"deny"}"#

    /// A local agent rule is merged after OpenCode's global `agent.build`
    /// rules, so a user-global allow cannot override the deny-all policy.
    static let openCodeIsolationConfigJSON = #"{"agent":{"build":{"permission":{"*":"deny"}}}}"#

    /// Returns the provider-capable environment for an isolated OpenCode pass.
    /// User-selected config paths are removed so only cmux's temporary project
    /// and the global provider discovery path remain visible.
    func openCodeSummarizerEnvironment(from env: [String: String]) -> [String: String] {
        let configOverrideKeys = [
            "OPENCODE_CONFIG",
            "OPENCODE_CONFIG_CONTENT",
            "OPENCODE_CONFIG_DIR",
            "OPENCODE_PROJECT_CONFIG"
        ]
        var selected = summarizerEnvironment(from: env).filter { key, _ in
            !configOverrideKeys.contains(key)
        }
        selected["OPENCODE_DISABLE_PROJECT_CONFIG"] = "1"
        selected["OPENCODE_CONFIG_CONTENT"] = Self.openCodeIsolationConfigJSON
        selected["OPENCODE_PERMISSION"] = Self.openCodeDenyAllPermissionsJSON
        selected["OPENCODE_PURE"] = "1"
        return selected
    }

    /// Argument vector for the tool-disabled `opencode run` summarizer call.
    static func openCodeSummarizerArguments(directory: String, promptPath: String) -> [String] {
        [
            "run",
            "--pure",
            "--format", "default",
            "--dir", directory,
            "--file", promptPath,
            "Generate a 2-5 word title from the attached conversation excerpt. Output only the title."
        ]
    }

    /// Argument vector for the tool-disabled `claude -p` summarizer call.
    func claudeSummarizerArguments(from env: [String: String]) -> [String] {
        [
            "-p",
            "--model", claudeModel(from: env),
            "--tools", "",
            "--disable-slash-commands",
            "--no-session-persistence",
            "--strict-mcp-config",
            "--mcp-config", Self.emptyMCPConfigJSON
        ]
    }
}

/// Builds the isolated Codex invocation used for workspace naming.
///
/// `--ignore-user-config` keeps tools, MCP servers, and rules out of the
/// summarizer, but it also removes the user's model provider. Re-apply only
/// the provider selection, its non-secret provider settings, and the selected
/// model. When the caller supplies a temporary `CODEX_HOME`, the provider
/// credentials remain in its mode-restricted config file instead of argv.
struct CodexAutoNamingArguments: Sendable {
    static func build(configToml: String?, usesTemporaryConfig: Bool = false) -> [String] {
        var arguments = [
            "exec",
            "-c", "default_tools_enabled=false",
            "-c", "tools={}",
            "-c", "mcp_servers={}",
            "-c", "web_search=\"disabled\"",
            "-c", "approval_policy=never",
            "-c", "shell_environment_policy.inherit=none",
            "--skip-git-repo-check",
            "--ephemeral",
            "--ignore-rules",
            "--sandbox", "read-only"
        ]
        if !usesTemporaryConfig {
            arguments.insert("--ignore-user-config", at: arguments.firstIndex(of: "--ignore-rules")!)
        }
        guard let configToml else { return arguments }
        let overrides = providerOverrides(
            from: configToml,
            usesTemporaryConfig: usesTemporaryConfig
        )
        for override in overrides.reversed() {
            arguments.insert(contentsOf: ["-c", override], at: 1)
        }
        return arguments
    }

    static func removingComment(from rawLine: Substring) -> Substring {
            var quote: Character?
            var escaped = false
            for index in rawLine.indices {
                let character = rawLine[index]
                if quote == "\"" {
                    if escaped {
                        escaped = false
                    } else if character == "\\" {
                        escaped = true
                    } else if character == "\"" {
                        quote = nil
                    }
                } else if quote == "'" {
                    if character == "'" {
                        quote = nil
                    }
                } else if character == "\"" || character == "'" {
                    quote = character
                } else if character == "#" {
                    return rawLine[..<index]
                }
            }
            return rawLine
    }
    private static func providerOverrides(
        from toml: String,
        usesTemporaryConfig: Bool
    ) -> [String] {
        var model: String?
        var modelProvider: String?
        var providerEntries: [(section: String, key: String, value: String)] = []
        var section = ""
        var multilineStringDelimiter: String?
        for rawLine in toml.split(whereSeparator: \.isNewline) {
            let line = removingComment(from: rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if let delimiter = multilineStringDelimiter {
                if line.range(of: delimiter) != nil {
                    multilineStringDelimiter = nil
                }
                continue
            }
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.first == "[", line.last == "]" {
                section = String(line.dropFirst().dropLast())
                continue
            }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespacesAndNewlines)
            for delimiter in ["\"\"\"", "'''"] {
                let occurrenceCount = value.components(separatedBy: delimiter).count - 1
                if occurrenceCount.isMultiple(of: 2) == false {
                    multilineStringDelimiter = delimiter
                    break
                }
            }
            if section.isEmpty {
                if key == "model" { model = String(value) }
                if key == "model_provider" { modelProvider = String(value) }
            } else if section.hasPrefix("model_providers.") {
                providerEntries.append((section, String(key), String(value)))
            }
        }
        guard let modelProvider,
              let providerName = providerNameFromValue(modelProvider),
              providerName.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else {
            return model.map { ["model=\($0)"] } ?? []
        }
        var result = ["model_provider=\(modelProvider)"]
        if let model { result.append("model=\(model)") }
        guard !usesTemporaryConfig else { return result }
        let providerPrefix = "model_providers.\(providerName)"
        result.append(contentsOf: providerEntries
            .filter { $0.section == providerPrefix || $0.section.hasPrefix(providerPrefix + ".") }
            .filter { !isCredentialBearingKey(section: $0.section, key: $0.key) }
            .map {
                let prefix = providerPrefix
                let nestedPath = String($0.section.dropFirst(prefix.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                let keyPath = nestedPath.isEmpty ? $0.key : "\(nestedPath).\($0.key)"
                return "model_providers.\(providerName).\(keyPath)=\($0.value)"
            })
        return result
    }

    private static func isCredentialBearingKey(section: String, key: String) -> Bool {
        func normalizeComponent(_ raw: String) -> String {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let unquoted = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            var decoded = ""
            var index = unquoted.startIndex
            while index < unquoted.endIndex {
                guard unquoted[index] == "\\" else {
                    decoded.append(unquoted[index])
                    index = unquoted.index(after: index)
                    continue
                }
                let escapeStart = index
                index = unquoted.index(after: index)
                guard index < unquoted.endIndex else {
                    decoded.append("\\")
                    break
                }
                let escape = unquoted[index]
                index = unquoted.index(after: index)
                switch escape {
                case "u", "U":
                    let length = escape == "u" ? 4 : 8
                    guard unquoted.distance(from: index, to: unquoted.endIndex) >= length else {
                        decoded.append(contentsOf: unquoted[escapeStart..<index])
                        continue
                    }
                    let end = unquoted.index(index, offsetBy: length)
                    let hex = String(unquoted[index..<end])
                    if let scalarValue = UInt32(hex, radix: 16),
                       let scalar = UnicodeScalar(scalarValue) {
                        decoded.unicodeScalars.append(scalar)
                        index = end
                    } else {
                        decoded.append(contentsOf: unquoted[escapeStart..<index])
                    }
                case "b": decoded.append("\u{8}")
                case "t": decoded.append("\t")
                case "n": decoded.append("\n")
                case "f": decoded.append("\u{c}")
                case "r": decoded.append("\r")
                case "\\": decoded.append("\\")
                case "\"": decoded.append("\"")
                default: decoded.append(contentsOf: unquoted[escapeStart..<index])
                }
            }
            return decoded.lowercased().replacingOccurrences(of: "-", with: "_")
        }
        let sectionComponents = section.split(separator: ".").map { normalizeComponent(String($0)) }
        if sectionComponents.contains(where: { $0 == "headers" || $0 == "http_headers" || $0 == "env_http_headers" }) {
            return true
        }
        let keyComponents = key.split(separator: ".").map { normalizeComponent(String($0)) }
        let normalized = keyComponents.joined(separator: ".")
        if let firstKeyComponent = keyComponents.first,
           firstKeyComponent == "headers"
            || firstKeyComponent == "http_headers"
            || firstKeyComponent == "env_http_headers" {
            return true
        }
        return normalized.contains("token")
            || normalized.contains("secret")
            || normalized.contains("password")
            || normalized.contains("credential")
            || normalized.contains("auth")
            || normalized.contains("api_key")
            || normalized.contains("apikey")
            || normalized.hasSuffix("_key")
            || normalized == "key"
    }

    private static func providerNameFromValue(_ value: String) -> String? {
        guard value.count >= 2, value.first == "\"", value.last == "\"" else { return nil }
        return String(value.dropFirst().dropLast())
    }
}

/// Strict argument parsing for the small set of native tmux-compat commands
/// that perform state-changing actions. The old handlers used `optionValue`
/// and filtered unknown flags, which made a typo execute against the default
/// target. Keep this parser pure so the accepted forms and rejection behavior
/// stay testable without a socket or app process.
struct TmuxCompatParsedArguments: Equatable, Sendable {
    let workspace: String?
    let surface: String?
    let window: String?
    let name: String?
    let bracketed: Bool
    let printOnly: Bool
    let commandText: String?
    let message: String?
}

enum TmuxCompatArgumentParser {
    private struct ScanResult {
        var values: [String: String] = [:]
        var flags: Set<String> = []
        var positional: [String] = []
    }

    static func parseClearHistory(_ args: [String]) throws -> TmuxCompatParsedArguments {
        let result = try scan(
            args,
            command: "clear-history",
            valueOptions: ["--workspace", "--surface", "--window"],
            flagOptions: []
        )
        guard result.positional.isEmpty else {
            throw CLIError(message: "clear-history: unexpected arguments: \(result.positional.joined(separator: " "))")
        }
        return make(result)
    }

    static func parsePasteBuffer(_ args: [String]) throws -> TmuxCompatParsedArguments {
        let result = try scan(
            args,
            command: "paste-buffer",
            valueOptions: ["--workspace", "--surface", "--window", "--name"],
            flagOptions: ["--bracketed"]
        )
        guard result.positional.isEmpty else {
            throw CLIError(message: "paste-buffer: unexpected arguments: \(result.positional.joined(separator: " "))")
        }
        return make(result)
    }

    static func parseRespawnPane(_ args: [String]) throws -> TmuxCompatParsedArguments {
        let result = try scan(
            args,
            command: "respawn-pane",
            valueOptions: ["--workspace", "--surface", "--window", "--command"],
            flagOptions: [],
            allowsPositional: true
        )
        if result.values["--command"] != nil, !result.positional.isEmpty {
            throw CLIError(message: "respawn-pane: unexpected arguments: \(result.positional.joined(separator: " "))")
        }
        let command = result.values["--command"] ?? result.positional.joined(separator: " ")
        return make(result, commandText: command.isEmpty ? nil : command)
    }

    static func parseDisplayMessage(_ args: [String]) throws -> TmuxCompatParsedArguments {
        let result = try scan(
            args,
            command: "display-message",
            valueOptions: [],
            flagOptions: ["-p", "--print"],
            allowsPositional: true
        )
        let message = result.positional.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return make(result, message: message.isEmpty ? nil : message)
    }

    private static func make(
        _ result: ScanResult,
        commandText: String? = nil,
        message: String? = nil
    ) -> TmuxCompatParsedArguments {
        TmuxCompatParsedArguments(
            workspace: result.values["--workspace"],
            surface: result.values["--surface"],
            window: result.values["--window"],
            name: result.values["--name"],
            bracketed: result.flags.contains("--bracketed"),
            printOnly: result.flags.contains("-p") || result.flags.contains("--print"),
            commandText: commandText,
            message: message
        )
    }

    private static func scan(
        _ args: [String],
        command: String,
        valueOptions: Set<String>,
        flagOptions: Set<String>,
        allowsPositional: Bool = false
    ) throws -> ScanResult {
        var result = ScanResult()
        var index = 0
        var terminated = false
        while index < args.count {
            let arg = args[index]
            if terminated {
                guard allowsPositional else {
                    throw CLIError(message: "\(command): unexpected argument: \(arg)")
                }
                result.positional.append(arg)
                index += 1
                continue
            }
            if arg == "--" {
                terminated = true
                index += 1
                continue
            }
            if let option = valueOptions.first(where: { arg == $0 || arg.hasPrefix("\($0)=") }) {
                let value: String
                if arg.hasPrefix("\(option)=") {
                    value = String(arg.dropFirst(option.count + 1))
                } else {
                    guard index + 1 < args.count, args[index + 1] != "--", !args[index + 1].hasPrefix("-") else {
                        throw CLIError(message: "\(command): \(option) requires a value")
                    }
                    value = args[index + 1]
                    index += 1
                }
                guard !value.isEmpty else {
                    throw CLIError(message: "\(command): \(option) requires a value")
                }
                result.values[option] = value
                index += 1
                continue
            }
            if flagOptions.contains(arg) {
                result.flags.insert(arg)
                index += 1
                continue
            }
            if arg.hasPrefix("-") {
                throw CLIError(message: "\(command): unknown option '\(arg)'")
            }
            guard allowsPositional else {
                throw CLIError(message: "\(command): unexpected argument: \(arg)")
            }
            result.positional.append(arg)
            index += 1
        }
        return result
    }
}

/// Pure auto-naming logic: throttle decisions, transcript extraction,
/// prompt construction, and response sanitization.
struct AutoNamingEngine: Sendable {
    var config: AutoNamingConfig

    init(config: AutoNamingConfig = AutoNamingConfig()) {
        self.config = config
    }

    // MARK: - Throttle

    func throttleDecision(
        snapshot: AutoNamingSessionSnapshot,
        transcriptLineCount: Int,
        now: Date
    ) -> AutoNamingThrottleDecision {
        guard !snapshot.userOwned else {
            return .skipUserOwned
        }
        guard transcriptLineCount >= config.minTranscriptLines else {
            return .skipShortTranscript
        }
        let nowInterval = now.timeIntervalSince1970
        if let inFlightAt = snapshot.inFlightAt, nowInterval - inFlightAt < config.inFlightExpiry {
            return .skipInFlight
        }
        guard let lastLineCount = snapshot.lastLineCount, snapshot.lastNamedAt != nil else {
            // First naming for this session always qualifies; this also seeds
            // the baseline for resumed sessions arriving with a large
            // pre-existing transcript. A failed pass records only lastAttemptAt
            // (not lastNamedAt), so honor the cooldown here too — otherwise a
            // persistently failing summarizer respawns on every turn end.
            if let lastAttemptAt = snapshot.lastAttemptAt, nowInterval - lastAttemptAt < config.minInterval {
                return .skipTooSoon
            }
            return .proceed(baseline: transcriptLineCount)
        }
        if transcriptLineCount < lastLineCount {
            return .reseedBaseline(to: transcriptLineCount)
        }
        // Cooldown anchors on the last attempt (success or failure), so a
        // session that named once and now keeps failing also backs off.
        if let cooldownAnchor = snapshot.lastAttemptAt ?? snapshot.lastNamedAt,
           nowInterval - cooldownAnchor < config.minInterval {
            return .skipTooSoon
        }
        if transcriptLineCount - lastLineCount < config.minLineGrowth {
            return .skipInsufficientGrowth
        }
        return .proceed(baseline: transcriptLineCount)
    }

    // MARK: - Transcript extraction (Claude Code JSONL)

    /// Extracts user/assistant text messages from Claude Code transcript
    /// JSONL lines. Tool results, thinking blocks, and non-text content are
    /// skipped; unparseable lines are ignored.
    func extractMessages(fromTranscriptLines lines: [String]) -> [AutoNamingTranscriptMessage] {
        var messages: [AutoNamingTranscriptMessage] = []
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                continue
            }
            guard let role = object["type"] as? String, role == "user" || role == "assistant" else {
                continue
            }
            guard let message = object["message"] as? [String: Any] else { continue }
            var text = ""
            if let content = message["content"] as? String {
                text = content
            } else if let content = message["content"] as? [[String: Any]] {
                text = content.compactMap { item -> String? in
                    guard item["type"] as? String == "text" else { return nil }
                    return item["text"] as? String
                }.joined(separator: "\n")
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            messages.append(AutoNamingTranscriptMessage(role: role, text: trimmed))
        }
        return messages
    }

    /// Returns whether a Claude transcript contains a non-empty native title
    /// record written by `/rename`.
    func containsClaudeCustomTitle(inTranscriptLines lines: [String]) -> Bool {
        lines.contains { line in
            guard let data = line.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  object["type"] as? String == "custom-title" else {
                return false
            }
            return (object["customTitle"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty == false
        }
    }

    /// Returns whether a Claude UserPromptSubmit payload starts with the
    /// native `/rename` command.
    func isClaudeRenamePrompt(_ prompt: String?) -> Bool {
        guard let prompt else { return false }
        let normalized = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count >= "/rename".count else { return false }
        let command = normalized.prefix("/rename".count).lowercased()
        guard command == "/rename" else { return false }
        return normalized.count == "/rename".count
            || normalized.dropFirst("/rename".count).first.map { $0.isWhitespace } == true
    }

    /// Builds the summarization context: the first user messages anchor the
    /// session's purpose, the trailing messages capture the current topic.
    func buildContext(from messages: [AutoNamingTranscriptMessage]) -> String? {
        guard !messages.isEmpty else { return nil }
        let headUser = messages
            .filter { $0.role == "user" }
            .prefix(config.contextHeadUserMessages)
        let tail = messages.suffix(config.contextTailMessages)
        var seen = Set<String>()
        var parts: [String] = []
        for message in Array(headUser) + Array(tail) {
            let excerpt = String(message.text.prefix(config.contextMessageMaxChars))
            let key = "\(message.role):\(excerpt)"
            guard seen.insert(key).inserted else { continue }
            parts.append("\(message.role): \(excerpt)")
        }
        let context = parts.joined(separator: "\n")
        return context.isEmpty ? nil : context
    }

    // MARK: - Transcript extraction (Codex rollout JSONL)

    /// Extracts user/assistant text messages from Codex rollout JSONL lines
    /// (`response_item` payloads of type `message`). Injected context blocks
    /// (environment context, user instructions, subagent notifications) are
    /// skipped along with tool calls and event noise.
    func extractCodexMessages(fromRolloutLines lines: [String]) -> [AutoNamingTranscriptMessage] {
        var messages: [AutoNamingTranscriptMessage] = []
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  object["type"] as? String == "response_item",
                  let payload = object["payload"] as? [String: Any],
                  payload["type"] as? String == "message",
                  let role = payload["role"] as? String, role == "user" || role == "assistant" else {
                continue
            }
            var text = ""
            if let content = payload["content"] as? String {
                text = content
            } else if let content = payload["content"] as? [[String: Any]] {
                text = content.compactMap { block -> String? in
                    (block["text"] as? String) ?? (block["input_text"] as? String)
                }.joined(separator: "\n")
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            // Codex injects a small set of framework envelopes as user
            // messages. Filter only those known wrappers; ordinary HTML-like
            // conversation text is part of the user's topic.
            if role == "user", isCodexInjectedContext(trimmed) { continue }
            messages.append(AutoNamingTranscriptMessage(role: role, text: trimmed))
        }
        return messages
    }

    private func isCodexInjectedContext(_ text: String) -> Bool {
        if text.hasPrefix("# AGENTS.md instructions for "),
           text.contains("\n<INSTRUCTIONS>") {
            return true
        }

        let tagNames = [
            "environment_context",
            "user_instructions",
            "subagent_notification",
            "permissions",
            "collaboration_mode",
            "turn_aborted"
        ]
        return tagNames.contains { tagName in
            let openPrefix = "<\(tagName)"
            guard text.hasPrefix(openPrefix), text.count > openPrefix.count else {
                return false
            }
            let openBoundary = text[text.index(text.startIndex, offsetBy: openPrefix.count)]
            guard openBoundary == ">" || openBoundary.isWhitespace else {
                return false
            }

            let closePrefix = "</\(tagName)"
            guard let closeRange = text.range(of: closePrefix, options: .backwards),
                  closeRange.upperBound < text.endIndex else {
                return false
            }
            let closeBoundary = text[closeRange.upperBound]
            guard closeBoundary == ">" || closeBoundary.isWhitespace,
                  let closeEnd = text[closeRange.upperBound...].firstIndex(of: ">") else {
                return false
            }
            let trailing = text[text.index(after: closeEnd)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return trailing.isEmpty
        }
    }

    // MARK: - Transcript extraction (Grok chat_history JSONL)

    /// Extracts user/assistant text messages from Grok's native
    /// `chat_history.jsonl` records. Injected metadata tags are removed from
    /// user messages, with `<user_query>` preferred when present.
    func extractGrokMessages(fromChatHistoryLines lines: [String]) -> [AutoNamingTranscriptMessage] {
        var messages: [AutoNamingTranscriptMessage] = []
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                continue
            }
            guard let role = firstString(in: object, keys: ["role", "type"])?.lowercased(),
                  role == "user" || role == "assistant" else {
                continue
            }
            let rawText = firstText(in: object, keys: ["content", "text", "message"])
            let text = role == "user" ? grokUserText(rawText) : rawText
            guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty else {
                continue
            }
            messages.append(AutoNamingTranscriptMessage(role: role, text: trimmed))
        }
        return messages
    }

    // MARK: - Transcript extraction (generic hook payload cache)

    /// Extracts conversation messages from generic hook payloads that carry
    /// prompt/assistant context. Agents without these fields simply yield no
    /// messages and are skipped by the caller.
    func extractHookMessages(fromPayloadObjects objects: [[String: Any]]) -> [AutoNamingTranscriptMessage] {
        var messages: [AutoNamingTranscriptMessage] = []
        for object in objects {
            appendHookMessage(role: "user", text: hookUserText(in: object), to: &messages)
            appendHookMessage(role: "assistant", text: hookAssistantText(in: object), to: &messages)

            for key in ["context", "notification", "data", "extra"] {
                guard let nested = object[key] as? [String: Any] else { continue }
                appendHookMessage(role: "user", text: hookUserText(in: nested), to: &messages)
                appendHookMessage(role: "assistant", text: hookAssistantText(in: nested), to: &messages)
            }
        }
        return messages
    }

    /// Converts hook-message progress into the line-growth unit used by the
    /// shared throttle. `totalMessageCount` is monotonic even when the recent
    /// message cache is capped, so long-running hook adapters can keep naming
    /// after the cache reaches its retention limit.
    func hookMessageLineEquivalentCount(
        _ messages: [AutoNamingTranscriptMessage],
        totalMessageCount: Int? = nil
    ) -> Int {
        let count = max(messages.count, totalMessageCount ?? 0)
        return count * config.minLineGrowth
    }

    // MARK: - Prompt and response

    func buildPrompt(currentTitle: String?, context: String) -> String {
        var lines: [String] = [
            "You name terminal workspace tabs for a developer running coding agents.",
            "Given a conversation excerpt, output ONLY a short title: 2-5 words,",
            "in the same language as the conversation, no quotes, no trailing punctuation.",
            ""
        ]
        if let currentTitle, !currentTitle.isEmpty {
            lines.append("The current title is: \(currentTitle)")
            lines.append("If that still accurately describes the conversation's main topic, output it EXACTLY as given.")
            lines.append("")
        }
        lines.append("Conversation excerpt:")
        lines.append(context)
        return lines.joined(separator: "\n")
    }

    /// Normalizes a summarizer response into a usable title, or `nil` when
    /// the response is unusable or matches the current title (no rename
    /// needed). Takes the first non-empty line, strips wrapping quotes,
    /// collapses whitespace, and enforces the length cap at a word boundary.
    func sanitizeResponse(_ raw: String?, currentTitle: String?) -> String? {
        guard let raw else { return nil }
        guard let firstLine = raw
            .components(separatedBy: .newlines)
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty }) else {
            return nil
        }
        var title = firstLine
        while title.count >= 2,
              let first = title.first, let last = title.last,
              (first == "\"" && last == "\"") || (first == "'" && last == "'") ||
              (first == "\u{201C}" && last == "\u{201D}") {
            title = String(title.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        title = title
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !title.isEmpty else { return nil }
        if title.count > config.maxTitleLength {
            let prefix = String(title.prefix(config.maxTitleLength))
            if let lastSpace = prefix.lastIndex(of: " "), prefix.distance(from: prefix.startIndex, to: lastSpace) > 0 {
                title = String(prefix[..<lastSpace])
            } else {
                title = prefix
            }
            title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !title.isEmpty else { return nil }
        if let currentTitle, title == currentTitle { return nil }
        return title
    }

    private func appendHookMessage(
        role: String,
        text: String?,
        to messages: inout [AutoNamingTranscriptMessage]
    ) {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return
        }
        if messages.last == AutoNamingTranscriptMessage(role: role, text: text) {
            return
        }
        messages.append(AutoNamingTranscriptMessage(role: role, text: text))
    }

    private func hookUserText(in object: [String: Any]) -> String? {
        firstText(in: object, keys: [
            "lastUserMessage",
            "last_user_message",
            "userPrompt",
            "user_prompt",
            "user_message",
            "userMessage",
            "prompt"
        ])
    }

    private func hookAssistantText(in object: [String: Any]) -> String? {
        firstText(in: object, keys: [
            "assistantPreamble",
            "assistant_preamble",
            "last_assistant_message",
            "lastAssistantMessage",
            "assistant_response",
            "assistantResponse"
        ])
    }

    private func grokUserText(_ value: String?) -> String? {
        guard let value else { return nil }
        if let userQuery = taggedContent(named: "user_query", in: value) {
            return userQuery
        }
        let withoutMetadata = ["user_info", "git_status", "system-reminder"].reduce(value) { partial, tag in
            removingTaggedContent(named: tag, from: partial)
        }
        return withoutMetadata.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func taggedContent(named tag: String, in text: String) -> String? {
        let openTag = "<\(tag)>"
        let closeTag = "</\(tag)>"
        guard let openRange = text.range(of: openTag) else { return nil }
        let bodyStart = openRange.upperBound
        guard let closeRange = text[bodyStart...].range(of: closeTag) else { return nil }
        let body = String(text[bodyStart..<closeRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : body
    }
    private func removingTaggedContent(named tag: String, from text: String) -> String {
        let openTag = "<\(tag)>"
        let closeTag = "</\(tag)>"
        var result = text
        while let openRange = result.range(of: openTag) {
            let bodyStart = openRange.upperBound
            guard let closeRange = result[bodyStart...].range(of: closeTag) else { break }
            result.removeSubrange(openRange.lowerBound..<closeRange.upperBound)
        }
        return result
    }
    private func firstString(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            guard let value = object[key] as? String else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }
    private func firstText(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            guard let text = firstTextValue(object[key]) else { continue }
            return text
        }
        return nil
    }
    private func firstTextValue(_ value: Any?) -> String? {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let values = value as? [Any] {
            let parts = values.compactMap(firstTextBlock)
            let joined = parts.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return joined.isEmpty ? nil : joined
        }
        if let block = value as? [String: Any] {
            return firstTextBlock(block)
        }
        return nil
    }
    private func firstTextBlock(_ value: Any) -> String? {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard let block = value as? [String: Any] else { return nil }
        if let type = firstString(in: block, keys: ["type"]),
           type.caseInsensitiveCompare("text") != .orderedSame,
           type.caseInsensitiveCompare("input_text") != .orderedSame,
           type.caseInsensitiveCompare("output_text") != .orderedSame {
            return nil
        }
        return firstString(in: block, keys: ["text", "input_text", "content"])
    }
}
