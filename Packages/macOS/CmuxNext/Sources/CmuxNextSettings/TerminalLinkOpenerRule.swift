public import Foundation

/// One rule of `terminal.linkOpener.rules`: which URLs, opened by which programs, go to which
/// target. Written as `<match> -> <target>`:
///
/// ```jsonc
/// "rules": [
///   "caller:aws -> chrome@Profile 1",                 // every URL the aws CLI opens
///   "caller:gh,git github.com/login -> safari",       // gh or git, on that page
///   "re:^https://[^/]*\\.corp\\.example\\.com/ -> system",
///   "* -> command:~/bin/pick-browser"                 // a script decides the rest
/// ]
/// ```
///
/// The match is any number of `caller:<glob>[,<glob>…]` terms and an optional URL pattern, with
/// the syntax of `browser.urlsToAlwaysOpenExternally`: plain text matches anywhere in the URL, `*`
/// and `?` are wildcards, `re:` starts a regular expression. A rule with no URL pattern matches
/// every URL; `*` alone says so too. A caller glob matches a process name of the program that
/// opened the URL or one of its parent processes (`aws`, `gh`, `gcloud`, `node`), ignoring case.
/// The target is a ``TerminalLinkOpenerTarget``.
public nonisolated struct TerminalLinkOpenerRule: Sendable, Hashable {
    /// The rule as written, for diagnostics and replies.
    public var text: String
    /// Caller globs; empty matches any caller.
    public var callers: [String]
    /// The URL pattern; nil matches any URL.
    public var urlPattern: String?
    public var target: TerminalLinkOpenerTarget

    /// Reads one rule; nil when it has no ` -> ` or names no target.
    public init?(_ text: String) {
        guard let arrow = text.range(of: "->") else { return nil }
        let lhs = text[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
        guard let target = TerminalLinkOpenerTarget(String(text[arrow.upperBound...])) else { return nil }
        var callers: [String] = []
        var pattern: [Substring] = []
        for token in lhs.split(separator: " ", omittingEmptySubsequences: true) {
            if token.lowercased().hasPrefix("caller:") {
                callers += token.dropFirst("caller:".count).split(separator: ",").map { String($0).lowercased() }
            } else {
                pattern.append(token)
            }
        }
        let joined = pattern.joined(separator: " ")
        self.text = text.trimmingCharacters(in: .whitespaces)
        self.callers = callers
        self.urlPattern = joined.isEmpty || joined == "*" ? nil : joined
        self.target = target
    }

    /// True when `url`, opened by a process chain named `callers`, matches.
    public func matches(_ url: URL, callers names: [String]) -> Bool {
        if !callers.isEmpty {
            let lowered = names.map { $0.lowercased() }
            guard callers.contains(where: { glob in lowered.contains { globMatches(glob, $0) } }) else { return false }
        }
        guard let urlPattern else { return true }
        return BrowserExternalURLPatternMatcher(patterns: [urlPattern]).matches(url.absoluteString)
    }
}

/// `*` and `?` wildcards over the whole name.
private func globMatches(_ pattern: String, _ name: String) -> Bool {
    let p = Array(pattern), n = Array(name)
    var pi = 0, ni = 0, star = -1, mark = 0
    while ni < n.count {
        if pi < p.count, p[pi] == "?" || p[pi] == n[ni] {
            pi += 1; ni += 1
        } else if pi < p.count, p[pi] == "*" {
            star = pi; mark = ni; pi += 1
        } else if star >= 0 {
            pi = star + 1; mark += 1; ni = mark
        } else {
            return false
        }
    }
    while pi < p.count, p[pi] == "*" { pi += 1 }
    return pi == p.count
}
