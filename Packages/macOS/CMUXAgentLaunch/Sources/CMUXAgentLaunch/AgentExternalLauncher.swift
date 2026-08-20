import Foundation

/// A user-declared launcher that wraps a built-in agent command.
///
/// cmux owns a fixed set of wrapper launchers (`cmux claude-teams`, `cmux codex-teams`, `cmux omo`,
/// …) and resolves their resume argv in
/// ``AgentResumeArgv/launcherResolution(launcher:sessionId:executablePath:arguments:)``. A launcher
/// cmux does NOT own is invisible to that resolution: a multi-account router such as
/// `teamclaude run --auto-fallback -- <claude argv>`, an LLM-gateway front end, or any
/// `<wrapper> run -- <agent argv>` shim execs the real agent as a child, so the capture records the
/// inner `claude` process and restore replays a bare `claude --resume <id>`. The wrapper is dropped
/// silently — traffic leaves the router, and whatever the wrapper provided (account fallback, quota
/// spreading, request logging) is gone from the restored pane.
/// https://github.com/manaflow-ai/cmux/issues/10494
///
/// Declaring the launcher in `cmux.json` re-supplies it at resume time. Detection runs against the
/// argv of the agent's ancestor processes at capture time, and the recorded id is replayed through
/// ``resumeArgvPrefix`` when the resume argv is built:
///
/// ```json
/// { "agents": { "launchers": [ {
///   "id": "teamclaude",
///   "kinds": ["claude"],
///   "detect": { "argvExecutables": ["teamclaude"] },
///   "resumeArgvPrefix": ["teamclaude", "run", "--auto-fallback", "--"]
/// } ] } }
/// ```
///
/// The declaration carries an argv PREFIX rather than a command template on purpose: the agent argv
/// cmux already builds (`--resume <id> --permission-mode auto`, plus every sanitizer-preserved
/// option) is reused verbatim, so a wrapper never has to restate the agent's own flags and no
/// second quoting layer is introduced.
public struct AgentExternalLauncher: Codable, Equatable, Sendable {
    /// How many leading argv words are considered when identifying a launcher process.
    ///
    /// A launcher is the command being run, so it appears at the front of its own argv — either as
    /// `argv[0]` (`teamclaude run …`) or just behind an interpreter or env prefix
    /// (`node /usr/local/bin/teamclaude run …`, `env VAR=1 llm-gateway exec …`). Options and paths
    /// further right belong to the launcher's own invocation (`--add-dir ~/src/teamclaude-notes`),
    /// and matching them would attribute a session to a launcher that never started it.
    public static let maximumIdentifyingArgvWords = 4

    /// Stable identifier recorded on the launch capture and replayed at resume time.
    public var id: String
    /// Built-in agent kinds this launcher wraps. Empty matches every kind.
    public var kinds: [String]
    /// Executable names or paths that identify the launcher process.
    ///
    /// A match requires one of the leading argv words — or that word's last path component — to
    /// equal an entry exactly. Substring matching is deliberately not used: an incidental
    /// `teamclaude` inside an unrelated path would otherwise rewrite a session's resume command.
    public var argvExecutables: [String]
    /// Argv words prepended to the agent's own resume argv.
    public var resumeArgvPrefix: [String]
    /// Whether the agent's own `argv[0]` is kept after the prefix.
    ///
    /// Wrappers that take the agent's options after a `--` separator (`teamclaude run -- --resume …`)
    /// re-exec their own agent binary and must not receive it, which is the default. Wrappers that
    /// take a full command instead (`env`-style, `nice`-style) need it, and set this to `true`.
    public var includesAgentExecutable: Bool
    /// Whether every field the user actually wrote decoded and normalized cleanly.
    ///
    /// A declaration with a present-but-unusable field fails closed (see ``isUsable``) instead of
    /// falling back to a broader behavior. `"kinds": []` is the case that matters most: silently
    /// treating it as "no kinds declared" would widen the launcher to every agent, which is the
    /// opposite of what a user narrowing it to one agent asked for.
    public let isWellFormed: Bool

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case kinds
        case detect
        case resumeArgvPrefix
        case includesAgentExecutable
    }

    private enum DetectCodingKeys: String, CodingKey {
        case argvExecutables
    }

    /// Creates an external launcher declaration.
    ///
    /// - Parameters:
    ///   - id: Stable identifier recorded on the launch capture.
    ///   - kinds: Built-in agent kinds this launcher wraps; empty matches every kind.
    ///   - argvExecutables: Executable names or paths identifying the launcher process.
    ///   - resumeArgvPrefix: Argv words prepended to the agent's own resume argv.
    ///   - includesAgentExecutable: Whether the agent's own `argv[0]` is kept after the prefix.
    ///   - isWellFormed: Whether the source declaration decoded cleanly.
    public init(
        id: String,
        kinds: [String] = [],
        argvExecutables: [String],
        resumeArgvPrefix: [String],
        includesAgentExecutable: Bool = false,
        isWellFormed: Bool = true
    ) {
        self.id = Self.normalized(id) ?? ""
        self.kinds = Self.normalizedList(kinds).map { $0.lowercased() }
        self.argvExecutables = Self.normalizedList(argvExecutables)
        self.resumeArgvPrefix = Self.normalizedList(resumeArgvPrefix)
        self.includesAgentExecutable = includesAgentExecutable
        self.isWellFormed = isWellFormed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var wellFormed = true

        func decodeStrings(_ key: CodingKeys) -> [String] {
            guard container.contains(key) else { return [] }
            if let values = try? container.decode([String].self, forKey: key) {
                let normalized = Self.normalizedList(values)
                if normalized.count != values.count || normalized.isEmpty { wellFormed = false }
                return normalized
            }
            if let value = try? container.decode(String.self, forKey: key) {
                guard let normalized = Self.normalized(value) else {
                    wellFormed = false
                    return []
                }
                return [normalized]
            }
            wellFormed = false
            return []
        }

        var id = ""
        if container.contains(.id) {
            if let raw = try? container.decode(String.self, forKey: .id) {
                id = raw
            } else {
                wellFormed = false
            }
        }

        var kinds: [String] = []
        if container.contains(.kinds) {
            kinds = decodeStrings(.kinds)
        } else if container.contains(.kind) {
            kinds = decodeStrings(.kind)
        }

        var argvExecutables: [String] = []
        if container.contains(.detect) {
            if let detect = try? container.nestedContainer(keyedBy: DetectCodingKeys.self, forKey: .detect),
               detect.contains(.argvExecutables) {
                if let values = try? detect.decode([String].self, forKey: .argvExecutables) {
                    argvExecutables = Self.normalizedList(values)
                    if argvExecutables.count != values.count || argvExecutables.isEmpty { wellFormed = false }
                } else if let value = try? detect.decode(String.self, forKey: .argvExecutables) {
                    if let normalized = Self.normalized(value) {
                        argvExecutables = [normalized]
                    } else {
                        wellFormed = false
                    }
                } else {
                    wellFormed = false
                }
            } else {
                wellFormed = false
            }
        }

        // Strictly an array: a single string would become one argv word, so `"teamclaude run --"`
        // would exec a program with that exact name instead of the three words the user meant.
        var prefix: [String] = []
        if container.contains(.resumeArgvPrefix) {
            if let values = try? container.decode([String].self, forKey: .resumeArgvPrefix) {
                prefix = Self.normalizedList(values)
                if prefix.count != values.count || prefix.isEmpty { wellFormed = false }
            } else {
                wellFormed = false
            }
        }

        var includesAgentExecutable = false
        if container.contains(.includesAgentExecutable) {
            if let value = try? container.decode(Bool.self, forKey: .includesAgentExecutable) {
                includesAgentExecutable = value
            } else {
                wellFormed = false
            }
        }

        self.init(
            id: id,
            kinds: kinds,
            argvExecutables: argvExecutables,
            resumeArgvPrefix: prefix,
            includesAgentExecutable: includesAgentExecutable,
            isWellFormed: wellFormed
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        if !kinds.isEmpty {
            try container.encode(kinds, forKey: .kinds)
        }
        var detect = container.nestedContainer(keyedBy: DetectCodingKeys.self, forKey: .detect)
        try detect.encode(argvExecutables, forKey: .argvExecutables)
        try container.encode(resumeArgvPrefix, forKey: .resumeArgvPrefix)
        if includesAgentExecutable {
            try container.encode(includesAgentExecutable, forKey: .includesAgentExecutable)
        }
    }

    /// Whether the declaration carries everything needed to detect and replay a launcher.
    ///
    /// A declaration without an id, without a detection entry, without a resume prefix, or with a
    /// field the user wrote but cmux could not use can never change a restore correctly, so the
    /// registry drops it instead of guessing a broader behavior.
    public var isUsable: Bool {
        guard isWellFormed, !id.isEmpty, Self.isValidID(id) else { return false }
        return !argvExecutables.isEmpty && !resumeArgvPrefix.isEmpty
    }

    /// Whether this launcher wraps `kind`.
    ///
    /// - Parameter kind: The built-in agent kind, for example `"claude"`.
    /// - Returns: `true` when the declaration lists `kind`, or lists no kind at all.
    public func wraps(kind: String) -> Bool {
        guard !kinds.isEmpty else { return true }
        let normalized = kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        return kinds.contains(normalized)
    }

    /// Whether `argv` is this launcher's own process.
    ///
    /// - Parameter argv: A candidate process argv.
    /// - Returns: `true` when one of the leading argv words, or its last path component, equals a
    ///   declared executable.
    public func matches(argv: [String]) -> Bool {
        guard !argvExecutables.isEmpty else { return false }
        for word in argv.prefix(Self.maximumIdentifyingArgvWords) {
            let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let basename = (trimmed as NSString).lastPathComponent
            for candidate in argvExecutables where trimmed == candidate || basename == candidate {
                return true
            }
        }
        return false
    }

    /// Wraps an agent's own resume argv in this launcher.
    ///
    /// - Parameter argv: The resume argv cmux built for the agent, including `argv[0]`.
    /// - Returns: The wrapped argv, or `argv` unchanged when nothing would be left to pass on.
    public func applyingResumePrefix(to argv: [String]) -> [String] {
        guard !argv.isEmpty else { return argv }
        let agentArguments = includesAgentExecutable ? argv : Array(argv.dropFirst())
        guard !agentArguments.isEmpty else { return argv }
        return resumeArgvPrefix + agentArguments
    }

    private static func isValidID(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func normalizedList(_ values: [String]) -> [String] {
        values.compactMap { normalized($0) }
    }
}
