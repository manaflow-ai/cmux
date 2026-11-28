public import Foundation

/// Where a URL goes when a program in a cmux terminal opens it in a browser (`aws login`,
/// `gh auth login`, `gcloud auth login`, a dev server's "open in browser"), from cmux.json:
///
/// ```jsonc
/// "terminal": {
///   "linkOpener": {
///     "default": "cmux",                           // cmux | system | chrome | app:<name> | command:<cmd> ...
///     "rules": ["caller:aws -> chrome@Profile 1"]  // first match wins; see TerminalLinkOpenerRule
///   }
/// }
/// ```
///
/// cmux terminals set `BROWSER` to the bundled `cmux-open-url`, and put `open` and `xdg-open`
/// shims first on `PATH` that send an http(s) URL there (any other `open` goes to `/usr/bin/open`).
/// It asks the app (`browser.open_link`), which picks the target here: the first rule that
/// matches, else ``defaultTarget``. A `BROWSER` the user sets wins over all of it, except
/// `BROWSER=open` (prezto's default when unset), which names no browser. When the app
/// cannot be reached the URL goes to the default browser. The macOS default browser never changes.
public nonisolated struct TerminalLinkOpener: Sendable, Hashable {
    /// The target when no rule matches. `cmux` by default.
    public var defaultTarget: TerminalLinkOpenerTarget
    /// The rules, first match wins.
    public var rules: [TerminalLinkOpenerRule]

    /// The paths and the default target's name are generated from
    /// schemas/settings/source/terminal.json; the JSON default always parses (`.cmux`).
    public static let fallback = TerminalLinkOpener(defaultTarget: TerminalLinkOpenerTarget(defaultDefault) ?? .cmux, rules: [])

    public init(defaultTarget: TerminalLinkOpenerTarget, rules: [TerminalLinkOpenerRule]) {
        self.defaultTarget = defaultTarget
        self.rules = rules
    }

    /// What decided one open: the target and the index of the rule that matched (nil: the default).
    public struct Decision: Sendable, Hashable {
        public var target: TerminalLinkOpenerTarget
        public var rule: Int?

        public init(target: TerminalLinkOpenerTarget, rule: Int?) {
            self.target = target
            self.rule = rule
        }
    }

    /// The target for `url` opened by the process chain `callers` (the opener's parent first).
    /// Rust decides (`link_rules.decide`).
    public func decide(_ url: URL, callers: [String]) -> Decision {
        decide(request(url, callers: callers))
    }

    /// ``decide(_:callers:)``, then a sign-in or device-code page that no rule matched opens in
    /// cmux whatever ``defaultTarget`` says, when `routing` keeps sign-in pages in cmux
    /// (``LinkRouting/keepsSignInPageInCmux(_:)``, `browser.openSignInPagesInCmux`). A rule is the
    /// person's explicit choice and still wins; any other link keeps the default.
    public func decide(_ url: URL, callers: [String], routing: LinkRouting) -> Decision {
        var request = request(url, callers: callers)
        request["routing"] = routing.jsonValue
        request["signInPage"] = .bool(SignInPage(url: url) != nil)
        return decide(request)
    }

    private func request(_ url: URL, callers: [String]) -> [String: JSONValue] {
        [
            "opener": .object(["default": defaultTarget.jsonValue, "rules": .array(rules.map { .string($0.text) })]),
            "url": .string(url.absoluteString),
            "callers": .array(callers.map(JSONValue.string)),
        ]
    }

    private func decide(_ request: [String: JSONValue]) -> Decision {
        let reply = SettingsRust.answer("link_rules.decide", .object(request))
        guard let target = reply["target"].flatMap(TerminalLinkOpenerTarget.init(json:)) else {
            return Decision(target: defaultTarget, rule: nil)
        }
        return Decision(target: target, rule: reply["rule"]?.intValue)
    }

    /// Rust reads the keys and their diagnostics (`link_rules.opener`).
    static func parse(_ root: JSONValue) -> (TerminalLinkOpener, [SettingsDiagnostic]) {
        let reply = SettingsRust.answer("link_rules.opener", .object(["root": root]))
        guard let opener = reply["opener"] else { return (fallback, []) }
        let setting = TerminalLinkOpener(
            defaultTarget: opener["default"].flatMap(TerminalLinkOpenerTarget.init(json:)) ?? fallback.defaultTarget,
            rules: (opener["rules"]?.arrayValue ?? []).compactMap(TerminalLinkOpenerRule.init(json:)))
        return (setting, LinkRouting.linkDiagnostics(reply))
    }
}
