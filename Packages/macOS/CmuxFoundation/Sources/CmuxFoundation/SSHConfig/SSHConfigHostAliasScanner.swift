/// Enumerates the concrete, connectable `Host` aliases declared in an OpenSSH
/// client configuration file.
///
/// The scanner walks a config file line by line, following `Include`
/// directives (with `glob(3)`-style expansion, bounded recursion depth, and
/// `~`/relative-path resolution matching `ssh(1)` semantics for user configs),
/// and collects every `Host` pattern that names a single real host:
///
/// - Pattern entries containing `*` or `?` wildcards are skipped.
/// - Negated (`!`) entries are skipped, and a concrete alias that matches a
///   negated pattern on its own `Host` line is skipped too (OpenSSH rejects
///   the whole block for such a target).
/// - Entries starting with `-` are skipped (not connectable as an
///   `ssh <destination>` argument).
/// - `Match` blocks and all other keywords are ignored.
///
/// `Include` directives inside a `Host` block are conditional in `ssh(1)`:
/// the included file is only read when the target host matches the enclosing
/// patterns. The scanner mirrors that by intersecting — an alias found under
/// one or more enclosing `Host` scopes is listed only when it matches every
/// enclosing pattern list, so every listed alias resolves when passed to
/// `ssh`. `Include` directives inside a `Match` block depend on conditions
/// that cannot be evaluated statically (user, exec, ...), so they are skipped
/// rather than risk listing aliases `ssh` would not honor.
///
/// Results preserve first-encounter order and are de-duplicated. All file
/// access goes through the injected ``SSHConfigFileReading`` seam, so parsing
/// is pure and unit-testable:
///
/// ```swift
/// let scanner = SSHConfigHostAliasScanner(
///     fileReader: SSHConfigFileSystemReader(),
///     homeDirectory: NSHomeDirectory()
/// )
/// let aliases = scanner.hostAliases(inConfigAtPath: scanner.defaultUserConfigPath)
/// ```
public struct SSHConfigHostAliasScanner: Sendable {
    /// Mirrors OpenSSH's include recursion guard so cyclic `Include` chains
    /// terminate.
    private static let maximumIncludeDepth = 16

    /// The filesystem seam used to read config files and expand include globs.
    public let fileReader: any SSHConfigFileReading

    /// The home directory used to resolve `~` prefixes and, via `~/.ssh`,
    /// relative `Include` arguments.
    public let homeDirectory: String

    /// Creates a scanner.
    ///
    /// - Parameters:
    ///   - fileReader: The filesystem seam; defaults to the real filesystem.
    ///   - homeDirectory: The home directory used for `~` and relative
    ///     `Include` resolution.
    public init(
        fileReader: any SSHConfigFileReading = SSHConfigFileSystemReader(),
        homeDirectory: String
    ) {
        self.fileReader = fileReader
        self.homeDirectory = homeDirectory
    }

    /// The per-user OpenSSH client config path (`~/.ssh/config`).
    public var defaultUserConfigPath: String {
        homeDirectory + "/.ssh/config"
    }

    /// Collects the concrete `Host` aliases reachable from the config file at
    /// `path`, following `Include` directives.
    ///
    /// - Parameter path: An absolute config file path.
    /// - Returns: De-duplicated aliases in first-encounter order; empty when
    ///   the file is missing or declares no concrete hosts.
    public func hostAliases(inConfigAtPath path: String) -> [String] {
        var seen: Set<String> = []
        var aliases: [String] = []
        collectAliases(
            fromConfigAtPath: path,
            enclosingHostScopes: [],
            depth: 0,
            seen: &seen,
            aliases: &aliases
        )
        return aliases
    }

    /// The block context an `Include` line inherits within one file: the top
    /// of a file is unconditional, and each `Host`/`Match` line starts a new
    /// block that scopes every following line until the next block line.
    private enum BlockScope {
        case unconditional
        case host(patterns: [String])
        case match
    }

    private func collectAliases(
        fromConfigAtPath path: String,
        enclosingHostScopes: [[String]],
        depth: Int,
        seen: inout Set<String>,
        aliases: inout [String]
    ) {
        guard depth < Self.maximumIncludeDepth,
              let contents = fileReader.contentsOfFile(atPath: path) else {
            return
        }
        var currentBlock = BlockScope.unconditional
        for rawLine in contents.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = Self.parse(configLine: rawLine)
            switch line {
            case .host(let patterns):
                currentBlock = .host(patterns: patterns)
                for pattern in patterns where Self.isConcreteAlias(pattern) {
                    // The alias must survive its own line's pattern list (a
                    // same-line negation kills the block for that target)
                    // and every enclosing conditional-include scope.
                    guard Self.aliasMatchesPatternList(pattern, patterns: patterns),
                          Self.alias(pattern, matchesEveryScopeIn: enclosingHostScopes) else { continue }
                    if seen.insert(pattern).inserted {
                        aliases.append(pattern)
                    }
                }
            case .match:
                currentBlock = .match
            case .include(let arguments):
                var childScopes = enclosingHostScopes
                switch currentBlock {
                case .unconditional:
                    break
                case .host(let patterns):
                    childScopes.append(patterns)
                case .match:
                    // Match conditions are not statically evaluable; skip the
                    // include instead of listing aliases ssh may never read.
                    continue
                }
                for argument in arguments {
                    for includePath in fileReader.filePaths(matchingGlob: resolvedIncludePattern(for: argument)) {
                        collectAliases(
                            fromConfigAtPath: includePath,
                            enclosingHostScopes: childScopes,
                            depth: depth + 1,
                            seen: &seen,
                            aliases: &aliases
                        )
                    }
                }
            case .other:
                continue
            }
        }
    }

    /// Whether an alias found under nested conditional includes would actually
    /// activate every enclosing `Host` block when `ssh <alias>` runs.
    private static func alias(_ alias: String, matchesEveryScopeIn scopes: [[String]]) -> Bool {
        scopes.allSatisfy { patterns in
            aliasMatchesPatternList(alias, patterns: patterns)
        }
    }

    /// `ssh_config(5)` pattern-list matching: the alias must match at least
    /// one positive pattern and no negated (`!`) pattern.
    private static func aliasMatchesPatternList(_ alias: String, patterns: [String]) -> Bool {
        var matched = false
        for pattern in patterns {
            if pattern.hasPrefix("!") {
                if wildcardMatches(alias[...], pattern: pattern.dropFirst()) {
                    return false
                }
            } else if !matched, wildcardMatches(alias[...], pattern: pattern[...]) {
                matched = true
            }
        }
        return matched
    }

    /// Shell-style `*`/`?` matching over the whole string, as used by
    /// `ssh_config(5)` host patterns (no path-component semantics).
    private static func wildcardMatches(_ text: Substring, pattern: Substring) -> Bool {
        guard let patternCharacter = pattern.first else { return text.isEmpty }
        switch patternCharacter {
        case "*":
            let rest = pattern.dropFirst()
            var candidate = text
            while true {
                if wildcardMatches(candidate, pattern: rest) { return true }
                guard !candidate.isEmpty else { return false }
                candidate = candidate.dropFirst()
            }
        case "?":
            guard !text.isEmpty else { return false }
            return wildcardMatches(text.dropFirst(), pattern: pattern.dropFirst())
        default:
            guard text.first == patternCharacter else { return false }
            return wildcardMatches(text.dropFirst(), pattern: pattern.dropFirst())
        }
    }

    /// Resolves an `Include` argument the way `ssh(1)` does for user configs:
    /// `~` expands to the home directory and relative paths are anchored at
    /// `~/.ssh`.
    private func resolvedIncludePattern(for argument: String) -> String {
        if argument == "~" {
            return homeDirectory
        }
        if argument.hasPrefix("~/") {
            return homeDirectory + argument.dropFirst(1)
        }
        if argument.hasPrefix("/") || argument.hasPrefix("~") {
            // Absolute paths pass through; unsupported `~user` forms stay
            // literal and simply match nothing.
            return argument
        }
        return homeDirectory + "/.ssh/" + argument
    }

    /// Returns whether a `Host` pattern names one concrete, connectable host:
    /// non-empty, not negated, free of `*`/`?` wildcards, and not starting
    /// with `-` (an `ssh <destination>` argument cannot start with a dash).
    private static func isConcreteAlias(_ pattern: String) -> Bool {
        !pattern.isEmpty
            && !pattern.hasPrefix("!")
            && !pattern.hasPrefix("-")
            && !pattern.contains("*")
            && !pattern.contains("?")
    }

    private enum ConfigLine {
        case host(patterns: [String])
        case include(arguments: [String])
        case match
        case other
    }

    /// Splits one config line into its keyword and arguments.
    ///
    /// Follows `ssh_config(5)` lexing closely enough for alias listing:
    /// keywords are case-insensitive and may be separated from their arguments
    /// by whitespace or a single `=`; arguments may be double-quoted to embed
    /// spaces; an unquoted `#` at the start of a token comments out the rest
    /// of the line.
    private static func parse(configLine line: Substring) -> ConfigLine {
        var index = line.startIndex
        skipSpaces(in: line, from: &index)
        guard index < line.endIndex, line[index] != "#" else { return .other }

        var keyword = ""
        while index < line.endIndex, !line[index].isWhitespace, line[index] != "=" {
            keyword.append(line[index])
            index = line.index(after: index)
        }
        skipSpaces(in: line, from: &index)
        if index < line.endIndex, line[index] == "=" {
            index = line.index(after: index)
            skipSpaces(in: line, from: &index)
        }

        switch keyword.lowercased() {
        case "host":
            return .host(patterns: arguments(in: line, from: index))
        case "include":
            return .include(arguments: arguments(in: line, from: index))
        case "match":
            return .match
        default:
            return .other
        }
    }

    private static func skipSpaces(in line: Substring, from index: inout Substring.Index) {
        while index < line.endIndex, line[index].isWhitespace {
            index = line.index(after: index)
        }
    }

    private static func arguments(in line: Substring, from start: Substring.Index) -> [String] {
        var tokens: [String] = []
        var index = start
        while true {
            skipSpaces(in: line, from: &index)
            guard index < line.endIndex else { break }
            if line[index] == "#" {
                break
            }
            var token = ""
            var isQuoted = false
            while index < line.endIndex {
                let character = line[index]
                if character == "\"" {
                    isQuoted.toggle()
                } else if character.isWhitespace, !isQuoted {
                    break
                } else {
                    token.append(character)
                }
                index = line.index(after: index)
            }
            if !token.isEmpty {
                tokens.append(token)
            }
        }
        return tokens
    }
}
