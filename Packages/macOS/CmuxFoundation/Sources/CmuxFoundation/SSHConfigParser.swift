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
    public init() {}

    /// Upper bound on `Include` nesting, mirroring OpenSSH, to bound work and
    /// break include cycles.
    static let maxIncludeDepth = 16

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
        collect(
            configText: configText,
            enclosingScope: .global,
            depth: 0,
            includeResolver: includeResolver,
            aliases: &aliases,
            seenAliases: &seenAliases,
            directives: &directives
        )
        return aliases.map { alias in
            resolve(alias: alias, directives: directives)
        }
    }

    // MARK: - Scoped directives

    /// The matching context a directive was seen in.
    enum Scope {
        /// Applies to every host (directives before any `Host`/`Match`).
        case global
        /// Applies to hosts matching these `Host` patterns.
        case host([HostPattern])
        /// A `Match` block (or anything we cannot evaluate statically); its
        /// directives are ignored and it contributes no aliases.
        case ignored
    }

    struct HostPattern: Equatable {
        let glob: String
        let negated: Bool
    }

    private struct ScopedDirective {
        let scope: Scope
        let key: String
        let value: String
    }

    /// Collect aliases and scoped directives from one config file's text.
    /// `enclosingScope` is the scope this file was reached under (`.global` for
    /// the top-level config, the enclosing `Host` scope for an included file).
    private func collect(
        configText: String,
        enclosingScope: Scope,
        depth: Int,
        includeResolver: (_ path: String) -> [String],
        aliases: inout [String],
        seenAliases: inout Set<String>,
        directives: inout [ScopedDirective]
    ) {
        var currentScope = enclosingScope
        // `isNewline` covers LF, CR, and the CRLF grapheme cluster (Swift treats
        // "\r\n" as one Character, so splitting on "\n" alone would miss it).
        for rawLine in configText.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }) {
            guard let (key, value) = Self.parseLine(String(rawLine)) else { continue }
            switch key {
            case "host":
                let patterns = Self.parsePatterns(value)
                currentScope = .host(patterns)
                for pattern in patterns where !pattern.negated && !Self.isWildcard(pattern.glob) {
                    // Only list an alias that is actually reachable. A `Host`
                    // line inside a file `Include`d under an enclosing `Host X`
                    // is conditional on X (verified against `ssh -G`), so the
                    // alias must match that enclosing scope to be a standalone
                    // host. At the top level (`.global`) every alias is reachable.
                    guard Self.scope(enclosingScope, matches: pattern.glob) else { continue }
                    if seenAliases.insert(pattern.glob).inserted {
                        aliases.append(pattern.glob)
                    }
                }
            case "match":
                currentScope = .ignored
            case "include":
                guard depth < Self.maxIncludeDepth else { continue }
                // An `Include` inside a `Match` block we cannot evaluate is
                // itself conditional; skip it (and the whole included file)
                // rather than leaking its `Host` entries into the static listing.
                if case .ignored = currentScope { continue }
                // ssh reads an `Include` only when its enclosing scope matches
                // the target, so the included file inherits `currentScope`.
                // Multiple whitespace-separated paths are allowed and a path
                // with spaces may be double-quoted, so tokenize and resolve each.
                for path in Self.tokenize(value) {
                    for includedText in includeResolver(path) {
                        collect(
                            configText: includedText,
                            enclosingScope: currentScope,
                            depth: depth + 1,
                            includeResolver: includeResolver,
                            aliases: &aliases,
                            seenAliases: &seenAliases,
                            directives: &directives
                        )
                    }
                }
            default:
                directives.append(ScopedDirective(scope: currentScope, key: key, value: value))
            }
        }
    }

    // MARK: - Resolution

    private func resolve(alias: String, directives: [ScopedDirective]) -> SSHConfigHost {
        var host = SSHConfigHost(alias: alias)
        for directive in directives where Self.scope(directive.scope, matches: alias) {
            switch directive.key {
            case "hostname":
                if host.hostName == nil { host.hostName = Self.unquote(directive.value) }
            case "user":
                if host.user == nil { host.user = Self.unquote(directive.value) }
            case "port":
                if host.port == nil { host.port = Int(Self.unquote(directive.value)) }
            case "identityfile":
                if host.identityFile == nil { host.identityFile = Self.unquote(directive.value) }
            case "proxyjump":
                if host.proxyJump == nil { host.proxyJump = Self.unquote(directive.value) }
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

    private static func scope(_ scope: Scope, matches alias: String) -> Bool {
        switch scope {
        case .global:
            return true
        case .ignored:
            return false
        case .host(let patterns):
            // ssh matches a Host line when the host matches at least one
            // positive pattern and no negated pattern.
            var matched = false
            for pattern in patterns where glob(pattern.glob, matches: alias) {
                if pattern.negated { return false }
                matched = true
            }
            return matched
        }
    }

    // MARK: - Line parsing

    /// Strip an inline `#` comment the way `ssh(1)` does: a `#` begins a
    /// comment (to end of line) only when it starts a whitespace-delimited
    /// token — i.e. it is at the start of the line or preceded by whitespace —
    /// and is not inside double quotes. A `#` in the middle of a token
    /// (`host#x`) or inside quotes (`"a # b"`) is literal. Verified against
    /// `ssh -G`: `HostName x # c` resolves to `x`, but `HostName x#c` and
    /// `HostName "x # c"` keep the hash.
    static func stripInlineComment(_ line: String) -> String {
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
    static func parseLine(_ raw: String) -> (key: String, value: String)? {
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
    static func tokenize(_ value: String) -> [String] {
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
    static func parsePatterns(_ value: String) -> [HostPattern] {
        tokenize(value).compactMap { token in
            var text = token
            var negated = false
            if text.hasPrefix("!") {
                negated = true
                text = String(text.dropFirst())
            }
            guard !text.isEmpty else { return nil }
            return HostPattern(glob: text, negated: negated)
        }
    }

    /// Strip one pair of surrounding double quotes from a single-valued
    /// argument (multi-token arguments are handled by `tokenize`).
    static func unquote(_ value: String) -> String {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
        return String(value.dropFirst().dropLast())
    }

    static func isWildcard(_ pattern: String) -> Bool {
        pattern.contains("*") || pattern.contains("?")
    }

    /// Classic shell-style wildcard match supporting `*` and `?`, case-sensitive
    /// like `ssh(1)` host matching.
    static func glob(_ pattern: String, matches text: String) -> Bool {
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
