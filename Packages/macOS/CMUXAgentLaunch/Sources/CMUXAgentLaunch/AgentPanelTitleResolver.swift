import Foundation

/// Extracts the stable identity that Claude Code supplies for a team member.
///
/// Claude's terminal title is the agent type (for example,
/// `general-purpose`), while the launch argv contains the human-selected
/// `--agent-name`.  The resolver keeps that metadata parsing independent from
/// the terminal/UI layers so every panel-spawn path can apply the same
/// name-first, type-fallback policy.
public struct AgentPanelTitleResolver: Sendable {
    /// Creates a stateless agent-panel title resolver.
    public init() {}

    /// The two Claude team identity fields that can be present in a launch.
    public struct Metadata: Equatable, Sendable {
        /// The human-selected teammate name, when supplied.
        public let name: String?
        /// Claude's role/type, used when no name was supplied.
        public let type: String?

        /// The title cmux should present for this agent panel.
        public var displayTitle: String? { name ?? type }

        init(name: String?, type: String?) {
            self.name = name
            self.type = type
        }
    }

    private static let maximumCommandNesting = 4
    private static let maximumTitleLength = 128
    private static let commandSeparators: Set<String> = ["&&", "||", ";", "|", "|&", "&"]
    private static let shellNames: Set<String> = [
        "ash", "bash", "csh", "dash", "fish", "ksh", "mksh", "nu", "pwsh", "sh", "tcsh", "zsh"
    ]
    private static let transparentCommandPrefixes: Set<String> = ["command", "exec"]

    /// Creates metadata from a process-style argv, including argv[0].
    ///
    /// The executable basename must be `claude`, unless the argv carries the
    /// complete teammate identity envelope used by Claude's versioned native
    /// executables. Similarly shaped name/type flags on an unrelated command
    /// are not treated as panel identity.
    ///
    /// Values may use either `--agent-name value` or
    /// `--agent-name=value` spelling. Once `--` is encountered, the remaining
    /// positional prompt is not treated as launch metadata.
    public func metadata(fromArguments arguments: [String]) -> Metadata? {
        Self.metadata(inArgumentVector: arguments)
    }

    /// Creates metadata from a shell command captured for a terminal surface.
    ///
    /// The command may contain `cd`, `env`, assignments, shell operators, or a
    /// nested `/bin/sh -lc '…'` wrapper. The parser intentionally does not
    /// execute or expand any shell text.
    public func metadata(fromCommand command: String) -> Metadata? {
        let tokens = Self.shellTokens(command)
        guard !tokens.isEmpty else { return nil }
        return Self.metadata(fromTokens: tokens, depth: 0)
    }

    /// Returns the preferred title from a set of launch-command candidates.
    /// A name from any candidate wins over every type, which keeps a wrapped
    /// command's fallback metadata from masking the actual teammate name.
    public func title(fromCommands commands: [String]) -> String? {
        var name: String?
        var type: String?
        for command in commands {
            guard let metadata = metadata(fromCommand: command) else { continue }
            name = name ?? metadata.name
            type = type ?? metadata.type
        }
        return name ?? type
    }

    private static func metadata(fromTokens tokens: [String], depth: Int) -> Metadata? {
        guard depth <= maximumCommandNesting else { return nil }

        var name: String?
        var type: String?
        for segment in commandSegments(tokens) {
            guard !segment.isEmpty else { continue }

            if let nested = nestedShellCommand(in: segment),
               let nestedMetadata = metadata(
                   fromCommand: nested,
                   depth: depth + 1
               ) {
                name = name ?? nestedMetadata.name
                type = type ?? nestedMetadata.type
            }

            let arguments = commandArguments(in: segment)
            guard !arguments.isEmpty,
                  let segmentMetadata = metadata(inArgumentVector: arguments) else {
                continue
            }
            name = name ?? segmentMetadata.name
            type = type ?? segmentMetadata.type
        }

        guard name != nil || type != nil else { return nil }
        return Metadata(name: name, type: type)
    }

    private static func metadata(fromCommand command: String, depth: Int) -> Metadata? {
        let tokens = shellTokens(command)
        guard !tokens.isEmpty else { return nil }
        return metadata(fromTokens: tokens, depth: depth)
    }

    private static func metadata(inArgumentVector arguments: [String]) -> Metadata? {
        guard arguments.count > 1 else { return nil }

        var name: String?
        var type: String?
        var hasAgentID = false
        var hasTeamName = false
        var hasParentSessionID = false
        var index = 1
        while index < arguments.count {
            let token = arguments[index]
            if token == "--" { break }

            if let value = optionValue(
                token: token,
                option: "--agent-name",
                following: arguments.dropFirst(index + 1).first
            ) {
                name = name ?? normalizedTitle(value.value)
                index += value.consumed
                continue
            }
            if let value = optionValue(
                token: token,
                option: "--agent-type",
                following: arguments.dropFirst(index + 1).first
            ) {
                type = type ?? normalizedTitle(value.value)
                index += value.consumed
                continue
            }
            if let value = optionValue(
                token: token,
                option: "--agent-id",
                following: arguments.dropFirst(index + 1).first
            ) {
                hasAgentID = hasAgentID || normalizedTitle(value.value) != nil
                index += value.consumed
                continue
            }
            if let value = optionValue(
                token: token,
                option: "--team-name",
                following: arguments.dropFirst(index + 1).first
            ) {
                hasTeamName = hasTeamName || normalizedTitle(value.value) != nil
                index += value.consumed
                continue
            }
            if let value = optionValue(
                token: token,
                option: "--parent-session-id",
                following: arguments.dropFirst(index + 1).first
            ) {
                hasParentSessionID = hasParentSessionID || normalizedTitle(value.value) != nil
                index += value.consumed
                continue
            }
            index += 1
        }

        let hasTeammateIdentityEnvelope = hasAgentID && hasTeamName && hasParentSessionID
        let hasValidatedClaudeExecutable = commandName(arguments[0]) == "claude"
            || (hasTeammateIdentityEnvelope && isVersionedNativeClaudeExecutable(arguments[0]))
        guard hasValidatedClaudeExecutable else { return nil }
        guard name != nil || type != nil else { return nil }
        return Metadata(name: name, type: type)
    }

    private static func isVersionedNativeClaudeExecutable(_ token: String) -> Bool {
        let components = token.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count >= 3,
              components.dropLast().suffix(2).elementsEqual(["claude", "versions"]),
              let version = components.last else {
            return false
        }

        let versionComponents = version.split(separator: ".", omittingEmptySubsequences: false)
        return versionComponents.count >= 3
            && versionComponents.allSatisfy { component in
                !component.isEmpty && component.allSatisfy(\.isNumber)
            }
    }

    private static func optionValue(
        token: String,
        option: String,
        following: String?
    ) -> (value: String, consumed: Int)? {
        if token == option {
            guard let following,
                  !following.hasPrefix("-") else {
                return nil
            }
            return (following, 2)
        }
        let prefix = option + "="
        guard token.hasPrefix(prefix) else { return nil }
        let value = String(token.dropFirst(prefix.count))
        guard !value.isEmpty else { return nil }
        return (value, 1)
    }

    private static func normalizedTitle(_ raw: String) -> String? {
        let pieces = raw.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        guard !pieces.isEmpty else { return nil }
        let value = pieces.joined(separator: " ")
        guard !value.hasPrefix("-") else { return nil }
        return String(value.prefix(maximumTitleLength))
    }

    private static func commandSegments(_ tokens: [String]) -> [[String]] {
        var segments: [[String]] = []
        var current: [String] = []
        for token in tokens {
            if commandSeparators.contains(token) {
                if !current.isEmpty { segments.append(current) }
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(token)
            }
        }
        if !current.isEmpty { segments.append(current) }
        return segments
    }

    /// Removes shell-only prefixes and returns the argv beginning at the real
    /// command. `env` assignments are deliberately skipped so flags in the
    /// command itself remain at stable argv positions.
    private static func commandArguments(in segment: [String]) -> [String] {
        var index = 0
        while index < segment.count {
            let token = segment[index]
            if isAssignment(token) {
                index += 1
                continue
            }

            let basename = commandName(token)
            if basename == "cd" {
                return []
            }
            if basename == "env" {
                index += 1
                while index < segment.count {
                    let option = segment[index]
                    if option == "--" {
                        index += 1
                        break
                    }
                    if isAssignment(option) {
                        index += 1
                        continue
                    }
                    if option.hasPrefix("-") {
                        index += 1
                        if option == "-u" || option == "--unset" {
                            index += 1
                        }
                        continue
                    }
                    break
                }
                continue
            }
            if transparentCommandPrefixes.contains(basename) {
                index += 1
                while index < segment.count {
                    let option = segment[index]
                    if option == "--" {
                        index += 1
                        break
                    }
                    guard option.hasPrefix("-") else { break }
                    index += 1
                    if basename == "exec", option == "-a", index < segment.count {
                        index += 1
                    }
                }
                continue
            }
            return Array(segment[index...])
        }
        return []
    }

    private static func nestedShellCommand(in segment: [String]) -> String? {
        let invocation = commandArguments(in: segment)
        guard !invocation.isEmpty else { return nil }

        let shellArguments: [String]
        if commandName(invocation[0]) == "login" {
            // Ghostty invokes `/usr/bin/login -flp <user> /bin/bash …` on
            // macOS. Only inspect a path-valued shell belonging to an actual
            // login invocation; a `/bin/sh -c …` string passed to `echo` (or
            // another ordinary process) must remain opaque data.
            guard let shellIndex = invocation.indices.dropFirst().first(where: { index in
                invocation[index].contains("/") && shellNames.contains(commandName(invocation[index]))
            }) else {
                return nil
            }
            shellArguments = Array(invocation[shellIndex...])
        } else {
            shellArguments = invocation
        }

        guard let shell = shellArguments.first,
              shellNames.contains(commandName(shell)) else {
            return nil
        }

        var index = 1
        while index < shellArguments.count {
            let token = shellArguments[index]
            if token == "--" {
                index += 1
                continue
            }
            if token == "-c" || (!token.hasPrefix("--") && token.hasPrefix("-") && token.contains("c")) {
                let commandIndex = index + 1
                guard commandIndex < shellArguments.count else { return nil }
                return shellArguments[commandIndex]
            }
            index += 1
        }
        return nil
    }

    private static func commandName(_ token: String) -> String {
        token.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? token
    }

    private static func isAssignment(_ token: String) -> Bool {
        guard let equals = token.firstIndex(of: "="), equals != token.startIndex else {
            return false
        }
        let name = token[..<equals]
        guard let first = name.first, first == "_" || first.isLetter else { return false }
        return name.allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }

    /// Tokenizes the small POSIX shell subset used by tmux start commands.
    /// Quotes are removed, but their contents remain one token; no expansion
    /// or command substitution is performed.
    private static func shellTokens(_ command: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inSingleQuote = false
        var inDoubleQuote = false
        var escaping = false
        let characters = Array(command)
        var index = 0

        func flush() {
            guard !current.isEmpty else { return }
            tokens.append(current)
            current.removeAll(keepingCapacity: true)
        }

        while index < characters.count {
            let character = characters[index]
            if escaping {
                current.append(character)
                escaping = false
                index += 1
                continue
            }
            if character == "\\" && !inSingleQuote {
                escaping = true
                index += 1
                continue
            }
            if character == "'" && !inDoubleQuote {
                inSingleQuote.toggle()
                index += 1
                continue
            }
            if character == "\"" && !inSingleQuote {
                inDoubleQuote.toggle()
                index += 1
                continue
            }
            if !inSingleQuote, !inDoubleQuote {
                if character.isWhitespace || character.isNewline {
                    flush()
                    index += 1
                    continue
                }
                if character == ";" {
                    flush()
                    tokens.append(";")
                    index += 1
                    continue
                }
                if character == "&" || character == "|" {
                    flush()
                    if index + 1 < characters.count, characters[index + 1] == character {
                        tokens.append(String([character, character]))
                        index += 2
                    } else if character == "|" && index + 1 < characters.count,
                              characters[index + 1] == "&" {
                        tokens.append("|&")
                        index += 2
                    } else {
                        tokens.append(String(character))
                        index += 1
                    }
                    continue
                }
            }
            current.append(character)
            index += 1
        }
        if escaping { current.append("\\") }
        flush()
        return tokens
    }
}
