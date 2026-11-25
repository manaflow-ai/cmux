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

    /// Reads one rule; nil when it has no ` -> ` or names no target. Rust reads it
    /// (`link_rules.opener_rule`).
    public init?(_ text: String) {
        let reply = SettingsRust.answer("link_rules.opener_rule", .object(["text": .string(text)]))
        guard let rule = reply["rule"].flatMap(Self.init(json:)) else { return nil }
        self = rule
    }

    /// A rule from its op form (`{text, callers, urlPattern, target}`).
    init?(json rule: JSONValue) {
        guard let written = rule["text"]?.stringValue,
              let target = rule["target"].flatMap(TerminalLinkOpenerTarget.init(json:)) else { return nil }
        self.text = written
        self.callers = rule["callers"]?.arrayValue?.compactMap(\.stringValue) ?? []
        self.urlPattern = rule["urlPattern"]?.stringValue
        self.target = target
    }

    /// True when `url`, opened by a process chain named `callers`, matches: the opener with this
    /// rule alone picks it (`link_rules.decide`).
    public func matches(_ url: URL, callers names: [String]) -> Bool {
        let opener = TerminalLinkOpener(defaultTarget: .cmux, rules: [self])
        return opener.decide(url, callers: names).rule == 0
    }
}
