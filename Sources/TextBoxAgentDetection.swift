import Foundation

enum TextBoxAgentDetection: CaseIterable {
    case claudeCode
    case codex
    case opencode
    case pi

    private var definitionID: String {
        switch self {
        case .claudeCode:
            return "claude"
        case .codex:
            return "codex"
        case .opencode:
            return "opencode"
        case .pi:
            return "pi"
        }
    }

    private var identityAliases: Set<String> {
        switch self {
        case .claudeCode:
            return ["claude", "claude_code", "claude-code", "claudecode", "omc"]
        case .codex:
            return ["codex", "omx"]
        case .opencode:
            return ["opencode", "open-code", "opencode-ai", "omo"]
        case .pi:
            return ["pi", "pi-coding-agent"]
        }
    }

    func matches(context: String) -> Bool {
        context
            .split(separator: "\n", omittingEmptySubsequences: false)
            .contains { matches(metadataLine: String($0)) }
    }

    static func supportsAgentPrefixes(context: String) -> Bool {
        allCases.contains { $0.matches(context: context) }
    }

    static func supportsActiveAgentPrefixes(context: String) -> Bool {
        allCases.contains { agent in
            context
                .split(separator: "\n", omittingEmptySubsequences: false)
                .contains { agent.matchesActive(metadataLine: String($0)) }
        }
    }

    static func hasPendingTextBoxLaunchContext(_ context: String) -> Bool {
        context
            .split(separator: "\n", omittingEmptySubsequences: false)
            .contains { line in
                metadataValue(String(line), prefix: "textBoxPendingLaunchCommand:") != nil
            }
    }

    static func activeTextBoxLaunchContext(from context: String) -> String? {
        context
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { line in
                allCases.contains { $0.matchesActive(metadataLine: line) }
            }
    }

    static func isClaudeCode(context: String) -> Bool {
        claudeCode.matches(context: context)
    }

    static func boundedLaunchCommandContext(from rawCommand: String) -> String? {
        let command = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return nil }
        return allCases.first { $0.matchesLaunchExecutable(command: command) }?.boundedActiveContextCommand
    }

    private var boundedActiveContextCommand: String {
        switch self {
        case .claudeCode:
            return "claude"
        case .codex:
            return "codex"
        case .opencode:
            return "opencode"
        case .pi:
            return "pi"
        }
    }

    private func matches(metadataLine rawLine: String) -> Bool {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return false }

        if let value = Self.metadataValue(line, prefix: "restoredAgent:") {
            return matchesIdentity(value)
        }
        if let value = Self.metadataValue(line, prefix: "agentPIDKey:") {
            return matchesIdentity(value)
        }
        if let value = Self.metadataValue(line, prefix: "initialCommand:") {
            return matchesCommand(value)
        }
        if let value = Self.metadataValue(line, prefix: "tmuxStartCommand:") {
            return matchesCommand(value)
        }
        if let value = Self.metadataValue(line, prefix: "textBoxLaunchCommand:") {
            return matchesLaunchExecutable(command: value)
        }
        return false
    }

    private func matchesActive(metadataLine rawLine: String) -> Bool {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return false }
        if let value = Self.metadataValue(line, prefix: "textBoxLaunchCommand:") {
            return matchesLaunchExecutable(command: value)
        }
        return false
    }

    private func matchesLaunchExecutable(command: String) -> Bool {
        let tokens = Self.shellLikeTokens(command)
        guard !tokens.isEmpty else { return false }
        return Self.commandSegments(from: tokens).contains { segment in
            matchesLaunchExecutableSegment(segment, depth: 0)
        }
    }

    private func matchesLaunchExecutableSegment(_ tokens: [String], depth: Int) -> Bool {
        guard !tokens.isEmpty else { return false }
        let resolved = Self.resolvedCommandSegment(tokens)
        guard let executable = resolved.arguments.first else { return false }
        let basename = (executable as NSString).lastPathComponent
        if matchesIdentity(basename) {
            return true
        }

        guard depth < 2 else { return false }
        return Self.shellSubcommandSegments(from: resolved.arguments).contains { segment in
            matchesLaunchExecutableSegment(segment, depth: depth + 1)
        }
    }

    private func matchesIdentity(_ rawValue: String) -> Bool {
        let normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return false }
        if identityAliases.contains(normalized) {
            return true
        }
        let baseKey = normalized.split(separator: ".").first.map(String.init) ?? normalized
        return identityAliases.contains(baseKey)
    }

    private func matchesCommand(_ command: String) -> Bool {
        let tokens = Self.shellLikeTokens(command)
        guard !tokens.isEmpty else { return false }
        return Self.commandSegments(from: tokens).contains { segment in
            matchesCommandSegment(segment, depth: 0)
        }
    }

    private func matchesCommandSegment(_ tokens: [String], depth: Int) -> Bool {
        guard !tokens.isEmpty else { return false }
        let resolved = Self.resolvedCommandSegment(tokens)
        guard let executable = resolved.arguments.first else { return false }
        if CmuxTaskManagerCodingAgentDefinition.matchingDefinition(
            processName: executable,
            processPath: executable,
            arguments: resolved.arguments,
            environment: resolved.environment
        )?.id == definitionID {
            return true
        }

        guard depth < 2 else { return false }
        return Self.shellSubcommandSegments(from: resolved.arguments).contains { segment in
            matchesCommandSegment(segment, depth: depth + 1)
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
