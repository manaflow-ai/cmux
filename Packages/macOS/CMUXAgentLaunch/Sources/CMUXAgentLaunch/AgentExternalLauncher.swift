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
    /// Commands that run another program named later in the same argv.
    ///
    /// Identification follows the executable position through these, so a launcher invoked as
    /// `node /usr/local/bin/teamclaude run` or `env VAR=1 VAR2=2 llm-gateway exec` is still found by
    /// its own name. Shells are deliberately absent: `sh -c "…"` carries its command inside a single
    /// string argument, and a shell that execs a program is replaced by it anyway, so the launcher
    /// shows up as its own process with its own argv.
    private static let executableForwardingCommands: Set<String> = [
        "env",
        "node", "nodejs", "bun", "bunx", "deno",
        "npx", "pnpm", "pnpx", "yarn",
        "python", "python3", "uv", "uvx", "pipx",
        "ruby", "perl", "php",
        "tsx", "ts-node",
    ]

    /// How many forwarding commands are followed before identification gives up.
    ///
    /// Two is enough for the real chains (`env … node script`, `npx … tsx script`); going deeper
    /// only increases the chance of mistaking an ordinary argument for the launcher.
    private static let maximumForwardingDepth = 2

    /// Stable identifier recorded on the launch capture and replayed at resume time.
    public var id: String
    /// Built-in agent kinds this launcher wraps. Empty matches every kind.
    public var kinds: [String]
    /// Executable names or paths that identify the launcher process.
    ///
    /// A match requires the argv's executable — or its last path component — to equal an entry
    /// exactly. Substring matching is deliberately not used: an incidental `teamclaude` inside an
    /// unrelated path would otherwise rewrite a session's resume command. Only the executable
    /// position is considered, so an argument that happens to carry the launcher's name
    /// (`--add-dir ~/src/teamclaude-notes`) never claims a session.
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
        if container.contains(.kinds), container.contains(.kind) {
            // `kind` and `kinds` state the same fact. Preferring one silently would hide the other,
            // so the declaration fails closed like every other unusable field here.
            wellFormed = false
        } else if container.contains(.kinds) {
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
    /// - Returns: `true` when the argv's executable, or its last path component, equals a declared
    ///   executable.
    public func matches(argv: [String]) -> Bool {
        guard !argvExecutables.isEmpty else { return false }
        for word in Self.identifyingExecutables(in: argv) {
            let basename = (word as NSString).lastPathComponent
            for candidate in argvExecutables where word == candidate || basename == candidate {
                return true
            }
        }
        return false
    }

    /// The words in `argv` that name a program being run.
    ///
    /// `argv[0]` always qualifies. When it is a command that runs another program named later in the
    /// same argv (``executableForwardingCommands``), the scan skips that command's own environment
    /// assignments and options and takes the next word too, up to
    /// ``maximumForwardingDepth`` levels.
    ///
    /// - Parameter argv: A process argv.
    /// - Returns: Executable words, outermost first.
    static func identifyingExecutables(in argv: [String]) -> [String] {
        var executables: [String] = []
        var index = 0
        var forwardsRemaining = maximumForwardingDepth

        while index < argv.count {
            let word = argv[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty else {
                index += 1
                continue
            }
            executables.append(word)
            guard forwardsRemaining > 0,
                  executableForwardingCommands.contains((word as NSString).lastPathComponent) else {
                return executables
            }
            forwardsRemaining -= 1
            index = indexOfForwardedExecutable(
                in: argv,
                after: index,
                forwardingCommand: (word as NSString).lastPathComponent
            )
        }
        return executables
    }

    /// The index of the program a forwarding command runs, skipping its own arguments.
    ///
    /// - Parameters:
    ///   - argv: The process argv being scanned.
    ///   - index: The index of the forwarding command itself.
    ///   - forwardingCommand: That command's basename, which decides how `-` is read.
    /// - Returns: The index of the program being run, or `argv.count` when there is none.
    private static func indexOfForwardedExecutable(
        in argv: [String],
        after index: Int,
        forwardingCommand: String
    ) -> Int {
        var cursor = index + 1
        while cursor < argv.count {
            let word = argv[cursor].trimmingCharacters(in: .whitespacesAndNewlines)
            if word.isEmpty {
                cursor += 1
                continue
            }
            // `env`-style `NAME=value` assignments precede the program being run.
            if isEnvironmentAssignment(word) {
                cursor += 1
                continue
            }
            // `--` ends the forwarding command's own option list, so the program follows it —
            // treating the separator as the program is how `env -- llm-gateway` lost its launcher.
            if word == "--" {
                cursor += 1
                continue
            }
            if word == "-" {
                // For `env`, a bare `-` is the `-i` shorthand and the program still follows.
                // Everywhere else it means "read the program from stdin", so nothing after it is an
                // executable: `node - llm-gateway` passes `llm-gateway` to a script on stdin.
                guard forwardingCommand == "env" else { return argv.count }
                cursor += 1
                continue
            }
            guard word.hasPrefix("-") else { return cursor }
            // Only options whose shape is known are skipped; anything else ends the search. Guessing
            // is what turns an option's value into a "launcher": `npx --package <pkg> wrapper` would
            // otherwise attribute the session to `<pkg>`.
            // `--opt=value` carries its value in the same word, so the program is one word closer
            // than the spaced form: `env --chdir=/tmp wrapper` versus `env --chdir /tmp wrapper`.
            let optionName = word.firstIndex(of: "=").map { String(word[word.startIndex..<$0]) } ?? word
            let carriesJoinedValue = optionName != word
            if forwardingCommand == "env" {
                if environmentCommandFlagOptions.contains(optionName) {
                    cursor += 1
                } else if environmentCommandValueOptions.contains(optionName) {
                    cursor += carriesJoinedValue ? 1 : 2
                } else {
                    return argv.count
                }
                continue
            }
            // An interpreter's options decide what its program even is, so none of them are skipped.
            if interpreterCommands.contains(forwardingCommand) {
                return argv.count
            }
            guard packageRunnerFlagOptions.contains(optionName) else { return argv.count }
            cursor += 1
        }
        return cursor
    }

    /// Forwarding commands that interpret code rather than dispatch to a named program.
    ///
    /// Their options decide what the program even is — `-e`/`-c` supply it inline, `-m` names a
    /// module, `-` reads it from stdin, `--loader`/`--import` change resolution — so identification
    /// stops at the first option instead of trying to classify each one. A wrapper is then found
    /// only in the plain `node /usr/local/bin/wrapper` form, which is how package-installed
    /// wrappers actually run; anything more exotic simply resumes unwrapped, which is the safe
    /// direction.
    private static let interpreterCommands: Set<String> = [
        "node", "nodejs", "bun", "deno",
        "python", "python3",
        "ruby", "perl", "php",
        "tsx", "ts-node",
    ]

    /// `env` options that stand alone, leaving the program in the next word.
    private static let environmentCommandFlagOptions: Set<String> = [
        "-i", "--ignore-environment",
        "-0", "--null",
        "-v", "--debug",
        "--list-signal-handling",
    ]

    /// `env` options whose value is the following word.
    private static let environmentCommandValueOptions: Set<String> = [
        "-u", "--unset",
        "-C", "--chdir",
        "-S", "--split-string",
        "-P", "--default-signal", "--ignore-signal", "--block-signal",
    ]

    /// Package-runner options that stand alone, leaving the program in the next word.
    ///
    /// Anything outside this set ends the search rather than being guessed at: a runner option that
    /// takes a value (`npx --package <pkg> wrapper`) would otherwise make the value look like the
    /// program, and one that carries a command (`npm -c "…"`) would make an argument look like it.
    private static let packageRunnerFlagOptions: Set<String> = [
        "-y", "--yes",
        "-q", "--quiet", "--silent",
        "--offline", "--prefer-offline", "--no-install", "--ignore-existing",
    ]

    private static func isEnvironmentAssignment(_ word: String) -> Bool {
        word.range(of: "^[A-Za-z_][A-Za-z0-9_]*=", options: .regularExpression) != nil
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
