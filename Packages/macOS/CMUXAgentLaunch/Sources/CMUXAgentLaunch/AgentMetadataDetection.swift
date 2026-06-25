public import Foundation

/// The handful of coding agents whose identity the text-box submission path needs to recognize from
/// a terminal's metadata context (restored-agent / agent-PID / initial-command / tmux-start lines).
///
/// This is a value enum the ``AgentMetadataDetector`` consults; each case knows the catalog ``id`` it
/// resolves to and the lowercased identity aliases that name it in metadata. It is intentionally a
/// small subset of the full ``AgentDefinition/builtIns`` catalog: only these agents drive text-box
/// submission behavior (e.g. Claude Code's ctrl+enter newline handling).
public enum DetectableAgent: String, CaseIterable, Sendable {
    /// Claude Code.
    case claudeCode
    /// OpenAI Codex.
    case codex
    /// OpenCode.
    case opencode

    /// The ``AgentDefinition/id`` this case resolves to in the agent catalog.
    public var definitionID: String {
        switch self {
        case .claudeCode:
            return "claude"
        case .codex:
            return "codex"
        case .opencode:
            return "opencode"
        }
    }

    /// Lowercased identity aliases that name this agent in a terminal metadata line.
    public var identityAliases: Set<String> {
        switch self {
        case .claudeCode:
            return ["claude", "claude_code", "claude-code", "claudecode", "omc"]
        case .codex:
            return ["codex", "omx"]
        case .opencode:
            return ["opencode", "open-code", "opencode-ai", "omo"]
        }
    }
}

/// Recognizes which coding agent (if any) a terminal is running, by parsing the terminal's metadata
/// context lines (`restoredAgent:` / `agentPIDKey:` / `initialCommand:` / `tmuxStartCommand:`) and
/// matching identity aliases or shell-tokenized launch commands against the agent catalog.
///
/// This is a real instance type holding a constructor-injected ``AgentDetector`` (default
/// ``AgentDetector/init(catalog:)``), so the catalog is built once and reused across calls. Callers
/// hold one of these and call its instance methods, replacing the previous static-only namespace.
/// Pure string work: no AppKit/SwiftUI, no app-type reach.
public struct AgentMetadataDetector: Sendable {
    /// The catalog-backed detector this matcher consults for command-segment recognition.
    public let detector: AgentDetector

    /// Creates a metadata detector over the given catalog-backed detector, defaulting to the
    /// built-in catalog.
    public init(detector: AgentDetector = AgentDetector()) {
        self.detector = detector
    }

    /// Whether the metadata `context` identifies a Claude Code agent.
    public func isClaudeCode(context: String) -> Bool {
        matches(agent: .claudeCode, context: context)
    }

    /// Whether the metadata `context` identifies any agent the text box supports prefix handling for.
    public func supportsAgentPrefixes(context: String) -> Bool {
        DetectableAgent.allCases.contains { matches(agent: $0, context: context) }
    }

    /// Whether the metadata `context` identifies the given `agent`.
    public func matches(agent: DetectableAgent, context: String) -> Bool {
        context
            .split(separator: "\n", omittingEmptySubsequences: false)
            .contains { matches(agent: agent, metadataLine: String($0)) }
    }

    private func matches(agent: DetectableAgent, metadataLine rawLine: String) -> Bool {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return false }

        if let value = Self.metadataValue(line, prefix: "restoredAgent:") {
            return matchesIdentity(agent: agent, value)
        }
        if let value = Self.metadataValue(line, prefix: "agentPIDKey:") {
            return matchesIdentity(agent: agent, value)
        }
        if let value = Self.metadataValue(line, prefix: "initialCommand:") {
            return matchesCommand(agent: agent, value)
        }
        if let value = Self.metadataValue(line, prefix: "tmuxStartCommand:") {
            return matchesCommand(agent: agent, value)
        }
        return false
    }

    private func matchesIdentity(agent: DetectableAgent, _ rawValue: String) -> Bool {
        let normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return false }
        if agent.identityAliases.contains(normalized) {
            return true
        }
        let baseKey = normalized.split(separator: ".").first.map(String.init) ?? normalized
        return agent.identityAliases.contains(baseKey)
    }

    private func matchesCommand(agent: DetectableAgent, _ command: String) -> Bool {
        let tokens = Self.shellLikeTokens(command)
        guard !tokens.isEmpty else { return false }
        return Self.commandSegments(from: tokens).contains { segment in
            matchesCommandSegment(agent: agent, segment, depth: 0)
        }
    }

    private func matchesCommandSegment(agent: DetectableAgent, _ tokens: [String], depth: Int) -> Bool {
        guard !tokens.isEmpty else { return false }
        let resolved = Self.resolvedCommandSegment(tokens)
        guard let executable = resolved.arguments.first else { return false }
        if detector.match(
            processName: executable,
            processPath: executable,
            arguments: resolved.arguments,
            environment: resolved.environment
        )?.id == agent.definitionID {
            return true
        }

        guard depth < 2 else { return false }
        return Self.shellSubcommandSegments(from: resolved.arguments).contains { segment in
            matchesCommandSegment(agent: agent, segment, depth: depth + 1)
        }
    }

    private static func metadataValue(_ line: String, prefix: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        return String(line.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func shellLikeTokens(_ command: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var escaping = false

        func flush() {
            guard !current.isEmpty else { return }
            tokens.append(current)
            current.removeAll(keepingCapacity: true)
        }

        for character in command {
            if escaping {
                current.append(character)
                escaping = false
                continue
            }
            if character == "\\" {
                escaping = true
                continue
            }
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                continue
            }
            if character.isWhitespace {
                flush()
                continue
            }
            current.append(character)
        }
        flush()
        return tokens
    }

    private static func commandSegments(from tokens: [String]) -> [[String]] {
        var result: [[String]] = []
        var current: [String] = []
        for token in tokens {
            if token == "&&" || token == "||" || token == ";" {
                if !current.isEmpty {
                    result.append(current)
                    current = []
                }
            } else {
                current.append(token)
            }
        }
        if !current.isEmpty {
            result.append(current)
        }
        return result
    }

    private static func resolvedCommandSegment(_ tokens: [String]) -> (arguments: [String], environment: [String: String]) {
        var environment: [String: String] = [:]
        var index = 0
        let firstBasename = tokens.first.map { ($0 as NSString).lastPathComponent.lowercased() }

        if firstBasename == "env" {
            index = 1
            while index < tokens.count {
                let token = tokens[index]
                if token.hasPrefix("-") {
                    index += 1
                    continue
                }
                guard let assignment = environmentAssignment(token) else { break }
                environment[assignment.key] = assignment.value
                index += 1
            }
        } else {
            while index < tokens.count {
                guard let assignment = environmentAssignment(tokens[index]) else { break }
                environment[assignment.key] = assignment.value
                index += 1
            }
        }

        let arguments = Array(tokens.dropFirst(index))
        return (arguments.isEmpty ? tokens : arguments, environment)
    }

    private static func shellSubcommandSegments(from arguments: [String]) -> [[String]] {
        guard let executable = arguments.first else { return [] }
        let basename = (executable as NSString).lastPathComponent.lowercased()
        guard ["sh", "bash", "zsh", "fish"].contains(basename) else { return [] }

        var commandStartIndex: Int?
        for index in arguments.indices.dropFirst() {
            let argument = arguments[index]
            if argument == "-c" || argument == "-lc" || argument == "-cl" {
                commandStartIndex = arguments.index(after: index)
                break
            }
            if argument.hasPrefix("-"),
               !argument.hasPrefix("--"),
               argument.dropFirst().contains("c") {
                commandStartIndex = arguments.index(after: index)
                break
            }
        }

        guard let commandStartIndex,
              commandStartIndex < arguments.endIndex else {
            return []
        }
        let commandTokens = shellLikeTokens(arguments[commandStartIndex])
        guard !commandTokens.isEmpty else { return [] }
        return commandSegments(from: commandTokens)
    }

    private static func environmentAssignment(_ token: String) -> (key: String, value: String)? {
        guard let equalsIndex = token.firstIndex(of: "="),
              equalsIndex != token.startIndex else {
            return nil
        }
        let key = String(token[..<equalsIndex])
        guard key.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else {
            return nil
        }
        return (key, String(token[token.index(after: equalsIndex)...]))
    }
}

/// A named terminal key the text box can forward, with the raw wire token each maps to.
///
/// The raw value is the token sent over the control wire (e.g. `"up"`, `"return"`). Lives in the
/// agent-launch package because both the text-box submission path and shortcut-routing tests resolve
/// keys by this raw value.
public enum TextBoxTerminalKey: String, Sendable {
    /// Up arrow (`"up"`).
    case arrowUp = "up"
    /// Down arrow (`"down"`).
    case arrowDown = "down"
    /// Left arrow (`"left"`).
    case arrowLeft = "left"
    /// Right arrow (`"right"`).
    case arrowRight = "right"
    /// Tab key (`"tab"`).
    case tab
    /// Backspace key (`"backspace"`).
    case backspace
    /// Escape key (`"escape"`).
    case escape
    /// Return/enter key (`"return"`).
    case returnKey = "return"
}
