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
///   "detect": { "argvContains": ["teamclaude"] },
///   "resumeArgvPrefix": ["teamclaude", "run", "--auto-fallback", "--"]
/// } ] } }
/// ```
///
/// The declaration carries an argv PREFIX rather than a command template on purpose: the agent argv
/// cmux already builds (`--resume <id> --permission-mode auto`, plus every sanitizer-preserved
/// option) is reused verbatim, so a wrapper never has to restate the agent's own flags and no
/// second quoting layer is introduced.
public struct AgentExternalLauncher: Codable, Equatable, Sendable {
    /// Stable identifier recorded on the launch capture and replayed at resume time.
    public var id: String
    /// Built-in agent kinds this launcher wraps. Empty matches every kind.
    public var kinds: [String]
    /// Argv substrings that identify the launcher process. Any match selects it.
    public var argvContains: [String]
    /// Argv words prepended to the agent's own resume argv.
    public var resumeArgvPrefix: [String]
    /// Whether the agent's own `argv[0]` is kept after the prefix.
    ///
    /// Wrappers that take the agent's options after a `--` separator (`teamclaude run -- --resume …`)
    /// re-exec their own agent binary and must not receive it, which is the default. Wrappers that
    /// take a full command instead (`env`-style, `nice`-style) need it, and set this to `true`.
    public var includesAgentExecutable: Bool

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case kinds
        case detect
        case resumeArgvPrefix
        case includesAgentExecutable
    }

    private enum DetectCodingKeys: String, CodingKey {
        case argvContains
    }

    /// Creates an external launcher declaration.
    ///
    /// - Parameters:
    ///   - id: Stable identifier recorded on the launch capture.
    ///   - kinds: Built-in agent kinds this launcher wraps; empty matches every kind.
    ///   - argvContains: Argv substrings identifying the launcher process.
    ///   - resumeArgvPrefix: Argv words prepended to the agent's own resume argv.
    ///   - includesAgentExecutable: Whether the agent's own `argv[0]` is kept after the prefix.
    public init(
        id: String,
        kinds: [String] = [],
        argvContains: [String],
        resumeArgvPrefix: [String],
        includesAgentExecutable: Bool = false
    ) {
        self.id = Self.normalized(id) ?? ""
        self.kinds = Self.normalizedList(kinds).map { $0.lowercased() }
        self.argvContains = Self.normalizedList(argvContains)
        self.resumeArgvPrefix = Self.normalizedList(resumeArgvPrefix)
        self.includesAgentExecutable = includesAgentExecutable
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        var kinds = Self.decodeOneOrManyStrings(forKey: .kinds, in: container)
        if kinds.isEmpty {
            kinds = Self.decodeOneOrManyStrings(forKey: .kind, in: container)
        }
        var argvContains: [String] = []
        if let detect = try? container.nestedContainer(keyedBy: DetectCodingKeys.self, forKey: .detect) {
            if let values = try? detect.decode([String].self, forKey: .argvContains) {
                argvContains = values
            } else if let value = try? detect.decode(String.self, forKey: .argvContains) {
                argvContains = [value]
            }
        }
        let prefix = (try? container.decode([String].self, forKey: .resumeArgvPrefix)) ?? []
        let includesAgentExecutable = (try? container.decode(Bool.self, forKey: .includesAgentExecutable)) ?? false
        self.init(
            id: id,
            kinds: kinds,
            argvContains: argvContains,
            resumeArgvPrefix: prefix,
            includesAgentExecutable: includesAgentExecutable
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        if !kinds.isEmpty {
            try container.encode(kinds, forKey: .kinds)
        }
        var detect = container.nestedContainer(keyedBy: DetectCodingKeys.self, forKey: .detect)
        try detect.encode(argvContains, forKey: .argvContains)
        try container.encode(resumeArgvPrefix, forKey: .resumeArgvPrefix)
        if includesAgentExecutable {
            try container.encode(includesAgentExecutable, forKey: .includesAgentExecutable)
        }
    }

    /// Whether the declaration carries everything needed to detect and replay a launcher.
    ///
    /// A declaration without an id, without a detection needle, or without a resume prefix can never
    /// change a restore, so the registry drops it instead of letting it shadow a later valid entry
    /// with the same id.
    public var isUsable: Bool {
        guard !id.isEmpty, Self.isValidID(id) else { return false }
        return !argvContains.isEmpty && !resumeArgvPrefix.isEmpty
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

    /// Whether `argv` looks like this launcher's own process.
    ///
    /// - Parameter argv: A candidate process argv.
    /// - Returns: `true` when any detection needle appears in any argv word.
    public func matches(argv: [String]) -> Bool {
        guard !argvContains.isEmpty else { return false }
        for word in argv {
            for needle in argvContains where word.contains(needle) {
                return true
            }
        }
        return false
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

    private static func decodeOneOrManyStrings(
        forKey key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>
    ) -> [String] {
        if let values = try? container.decode([String].self, forKey: key) {
            return values
        }
        if let value = try? container.decode(String.self, forKey: key) {
            return [value]
        }
        return []
    }
}
