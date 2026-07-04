import Foundation

/// Parses an OpenSSH client configuration into the list of concrete hosts it
/// defines (``SSHConfigHost``), applying `Host`-pattern matching and
/// first-obtained-value precedence the way `ssh(1)` does.
///
/// The parser is pure: it operates on configuration *text*. `Include`
/// directives are expanded through an injected resolver so filesystem globbing
/// (and the seams that replace it in tests) live in the caller, keeping this
/// type hermetic and unit-testable.
///
/// Known simplifications: `Match` blocks cannot be evaluated statically, so
/// their directives are ignored; `Tokens`/`%`-expansion in values is left
/// verbatim. Single-valued directives use first-match-wins; forwards
/// accumulate across every matching block.
public struct SSHConfigParser: Sendable {
    /// Creates a parser. It holds no state, so a single instance can parse any
    /// number of configurations.
    public init() {}

    /// Upper bound on `Include` nesting, mirroring OpenSSH.
    static let maxIncludeDepth = 16

    /// Upper bound on resolver calls for one parse, preventing duplicate
    /// include graphs from fanning out exponentially.
    static let maxIncludeExpansions = 4096

    /// Parse `configText` into the concrete hosts it defines.
    ///
    /// - Parameters:
    ///   - configText: the contents of an `ssh_config` file.
    ///   - includeResolver: expands a single `Include` *path* into the contents
    ///     of each file it matches, in the order ssh would read them. The parser
    ///     tokenizes a multi-path / quoted `Include` argument and calls this
    ///     once per path. The default ignores includes.
    /// - Returns: hosts in first-seen order. Pure-wildcard `Host` patterns
    ///   (`*`, `db-*`, negations) still configure matching hosts but are never
    ///   returned as entries themselves.
    public func hosts(
        configText: String,
        includeResolver: (_ path: String) -> [String] = { _ in [] }
    ) -> [SSHConfigHost] {
        var aliases: [String] = []
        var seenAliases = Set<String>()
        var directives: [ScopedDirective] = []
        var includeExpansions = 0
        var activeIncludePaths = Set<String>()
        collect(
            configText: configText,
            enclosingConditions: [],
            depth: 0,
            includeResolver: includeResolver,
            aliases: &aliases,
            seenAliases: &seenAliases,
            directives: &directives,
            includeExpansions: &includeExpansions,
            activeIncludePaths: &activeIncludePaths
        )
        return aliases.map { alias in
            resolve(alias: alias, directives: directives)
        }
    }

    // MARK: - Scoped directives
    //
    // The `Scope` enum lives in SSHConfigParser+Scope.swift (one major type per
    // file). These two trivial aggregates stay here as tuple typealiases.

    /// A single `Host` pattern: its glob text plus whether it was negated (`!`).
    typealias HostPattern = (glob: String, negated: Bool)

    /// A directive captured with the ``Scope`` it was seen in.
    typealias ScopedDirective = (scope: Scope, key: String, value: String)

    /// Collect aliases and scoped directives from one config file's text.
    /// `enclosingConditions` is the conjunction of `Host` conditions this file
    /// was reached under (`[]` for the top-level config; the enclosing `Host`
    /// conditions for a conditionally-included file).
    private func collect(
        configText: String,
        enclosingConditions: [[HostPattern]],
        depth: Int,
        includeResolver: (_ path: String) -> [String],
        aliases: inout [String],
        seenAliases: inout Set<String>,
        directives: inout [ScopedDirective],
        includeExpansions: inout Int,
        activeIncludePaths: inout Set<String>
    ) {
        let enclosingScope: Scope = .conditions(enclosingConditions)
        var currentScope = enclosingScope
        // `isNewline` covers LF, CR, and the CRLF grapheme cluster (Swift treats
        // "\r\n" as one Character, so splitting on "\n" alone would miss it).
        for rawLine in configText.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }) {
            guard let (key, value) = parseLine(String(rawLine)) else { continue }
            switch key {
            case "host":
                let patterns = parsePatterns(value)
                // AND this `Host` line onto the conditions the file was included
                // under: ssh reads a conditional include only for targets that
                // match the enclosing condition, so directives here apply to the
                // intersection, not to every listed alias.
                currentScope = .conditions(enclosingConditions + [patterns])
                for pattern in patterns where !pattern.negated && !isWildcard(pattern.glob) {
                    // List the alias only if it is reachable under the enclosing
                    // condition (verified against `ssh -G`). At the top level
                    // the enclosing condition is empty, so every alias is listed.
                    guard scope(enclosingScope, matches: pattern.glob) else { continue }
                    if seenAliases.insert(pattern.glob).inserted {
                        aliases.append(pattern.glob)
                    }
                }
            case "match":
                currentScope = .ignored
            case "include":
                guard depth < Self.maxIncludeDepth else { continue }
                // An `Include` inside a `Match` block we cannot evaluate is
                // itself conditional; skip it (and the whole included file). The
                // included file inherits the current conjunction of conditions.
                guard case .conditions(let childConditions) = currentScope else { continue }
                // Multiple whitespace-separated paths are allowed and a path
                // with spaces may be double-quoted, so tokenize and resolve each.
                for path in tokenize(value) {
                    guard includeExpansions < Self.maxIncludeExpansions else { continue }
                    guard activeIncludePaths.insert(path).inserted else { continue }
                    includeExpansions += 1
                    for includedText in includeResolver(path) {
                        collect(
                            configText: includedText,
                            enclosingConditions: childConditions,
                            depth: depth + 1,
                            includeResolver: includeResolver,
                            aliases: &aliases,
                            seenAliases: &seenAliases,
                            directives: &directives,
                            includeExpansions: &includeExpansions,
                            activeIncludePaths: &activeIncludePaths
                        )
                    }
                    activeIncludePaths.remove(path)
                }
            default:
                directives.append((scope: currentScope, key: key, value: value))
            }
        }
    }

    // MARK: - Resolution

    private func resolve(alias: String, directives: [ScopedDirective]) -> SSHConfigHost {
        var host = SSHConfigHost(alias: alias)
        for directive in directives where scope(directive.scope, matches: alias) {
            switch directive.key {
            case "hostname":
                if host.hostName == nil { host.hostName = unquote(directive.value) }
            case "user":
                if host.user == nil { host.user = unquote(directive.value) }
            case "port":
                if host.port == nil { host.port = Int(unquote(directive.value)) }
            case "identityfile":
                if host.identityFile == nil { host.identityFile = unquote(directive.value) }
            case "proxyjump":
                if host.proxyJump == nil { host.proxyJump = unquote(directive.value) }
            case "localforward":
                host.localForwards.append(directive.value)
            case "remoteforward":
                host.remoteForwards.append(directive.value)
            case "dynamicforward":
                host.dynamicForwards.append(directive.value)
            default:
                break
            }
        }
        return host
    }

    /// Whether `alias` matches `scope`: every condition in the conjunction must
    /// match (an empty conjunction is global). A `Match`/ignored scope never
    /// matches.
    private func scope(_ scope: Scope, matches alias: String) -> Bool {
        switch scope {
        case .ignored:
            return false
        case .conditions(let conditionSets):
            return conditionSets.allSatisfy { hostLineMatches($0, alias) }
        }
    }

    /// Whether `alias` satisfies one `Host`-line condition set: it matches at
    /// least one positive pattern and no negated pattern (ssh `Host` semantics).
    private func hostLineMatches(_ patterns: [HostPattern], _ alias: String) -> Bool {
        var matched = false
        for pattern in patterns where glob(pattern.glob, matches: alias) {
            if pattern.negated { return false }
            matched = true
        }
        return matched
    }

    // MARK: - Line parsing

    /// Strip an inline `#` comment the way `ssh(1)` does: a `#` begins a
    /// comment (to end of line) only when it starts a whitespace-delimited
    /// token — i.e. it is at the start of the line or preceded by whitespace —
    /// and is not inside double quotes. A `#` in the middle of a token
    /// (`host#x`) or inside quotes (`"a # b"`) is literal. Verified against
    /// `ssh -G`: `HostName x # c` resolves to `x`, but `HostName x#c` and
    /// `HostName "x # c"` keep the hash.
    func stripInlineComment(_ line: String) -> String {
        var result = ""
        var inQuotes = false
        var precededByWhitespace = true // the line start behaves like whitespace
        for character in line {
            if character == "\"" {
                inQuotes.toggle()
                result.append(character)
                precededByWhitespace = false
                continue
            }
            if character == "#", !inQuotes, precededByWhitespace {
                break
            }
            result.append(character)
            precededByWhitespace = character.isWhitespace
        }
        return result
    }

    /// Split a config line into a lowercased keyword and its raw argument
    /// string. Returns nil for blank lines, comments, and keyword-only lines.
    /// Keyword/argument may be separated by whitespace, by `=`, or by both
    /// (OpenSSH allows all three); inline `#` comments are stripped. The
    /// argument is returned verbatim (quotes intact) because multi-token
    /// arguments (`Host`, `Include`) must be tokenized quote-aware before any
    /// unquoting; single-valued consumers unquote in `resolve`.
    func parseLine(_ raw: String) -> (key: String, value: String)? {
        var line = Substring(stripInlineComment(raw))
        line = line.drop(while: { $0.isWhitespace })
        guard let first = line.first, first != "#" else { return nil }
        guard let sepIndex = line.firstIndex(where: { $0.isWhitespace || $0 == "=" }) else {
            return nil
        }
        let key = line[..<sepIndex].lowercased()
        var rest = line[sepIndex...]
        rest = rest.drop(while: { $0.isWhitespace })
        if rest.first == "=" {
            rest = rest.dropFirst()
            rest = rest.drop(while: { $0.isWhitespace })
        }
        let value = String(rest).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return (key, value)
    }

    /// Split an argument string into whitespace-separated tokens, honoring
    /// double quotes so a single token may contain spaces. OpenSSH allows
    /// quoting `Host` patterns and `Include` paths that contain whitespace.
    /// Surrounding quotes are removed from each token.
    func tokenize(_ value: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        var hasToken = false
        for character in value {
            if character == "\"" {
                inQuotes.toggle()
                hasToken = true
                continue
            }
            if character.isWhitespace, !inQuotes {
                if hasToken {
                    tokens.append(current)
                    current = ""
                    hasToken = false
                }
                continue
            }
            current.append(character)
            hasToken = true
        }
        if hasToken {
            tokens.append(current)
        }
        return tokens
    }

    /// Parse a `Host` line's patterns, honoring `!` negation and per-pattern
    /// quoting.
    func parsePatterns(_ value: String) -> [HostPattern] {
        tokenize(value).compactMap { token in
            var text = token
            var negated = false
            if text.hasPrefix("!") {
                negated = true
                text = String(text.dropFirst())
            }
            guard !text.isEmpty else { return nil }
            return (glob: text, negated: negated)
        }
    }

    /// Strip one pair of surrounding double quotes from a single-valued
    /// argument (multi-token arguments are handled by `tokenize`).
    func unquote(_ value: String) -> String {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
        return String(value.dropFirst().dropLast())
    }

    /// Whether a `Host` pattern contains a wildcard. OpenSSH `Host`/`Match`
    /// pattern matching (match.c) supports only `*` and `?` — NOT glob(3)
    /// `[...]` character classes — so `db[12]` is a literal host, not a pattern
    /// (verified against `ssh -G`: `ssh db1` does not match `Host db[12]`).
    /// Brackets are therefore not wildcards.
    func isWildcard(_ pattern: String) -> Bool {
        pattern.contains("*") || pattern.contains("?")
    }

    /// Classic shell-style wildcard match supporting `*` and `?`, case-sensitive
    /// like `ssh(1)` host matching. Any other character — including `[` / `]` —
    /// is matched literally, matching OpenSSH (which does not treat brackets as
    /// character classes in `Host` patterns).
    func glob(_ pattern: String, matches text: String) -> Bool {
        let p = Array(pattern)
        let t = Array(text)
        var pi = 0
        var ti = 0
        var starIndex = -1
        var matchIndex = 0
        while ti < t.count {
            if pi < p.count, p[pi] == "?" || p[pi] == t[ti] {
                pi += 1
                ti += 1
            } else if pi < p.count, p[pi] == "*" {
                starIndex = pi
                matchIndex = ti
                pi += 1
            } else if starIndex != -1 {
                pi = starIndex + 1
                matchIndex += 1
                ti = matchIndex
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}
