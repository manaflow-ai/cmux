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

    public static let fallback = TerminalLinkOpener(defaultTarget: .cmux, rules: [])
    public static let defaultPath = ["terminal", "linkOpener", "default"]
    public static let rulesPath = ["terminal", "linkOpener", "rules"]

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
    public func decide(_ url: URL, callers: [String]) -> Decision {
        if let index = rules.firstIndex(where: { $0.matches(url, callers: callers) }) {
            return Decision(target: rules[index].target, rule: index)
        }
        return Decision(target: defaultTarget, rule: nil)
    }

    /// ``decide(_:callers:)``, then a sign-in or device-code page that no rule matched opens in
    /// cmux whatever ``defaultTarget`` says, when `routing` keeps sign-in pages in cmux
    /// (``LinkRouting/keepsSignInPageInCmux(_:)``, `browser.openSignInPagesInCmux`). A rule is the
    /// person's explicit choice and still wins; any other link keeps the default.
    public func decide(_ url: URL, callers: [String], routing: LinkRouting) -> Decision {
        let decision = decide(url, callers: callers)
        guard decision.rule == nil, routing.keepsSignInPageInCmux(url) else { return decision }
        return Decision(target: .cmux, rule: nil)
    }

    static func parse(_ root: JSONValue) -> (TerminalLinkOpener, [SettingsDiagnostic]) {
        var setting = fallback
        var diagnostics: [SettingsDiagnostic] = []
        if let value = root.value(at: defaultPath) {
            if let text = value.stringValue, let target = TerminalLinkOpenerTarget(text) {
                setting.defaultTarget = target
            } else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: defaultPath.joined(separator: "."),
                                                      message: "expected cmux, system, a browser (chrome, safari, arc, firefox, edge, brave), app:<name> or command:<command>"))
            }
        }
        if let value = root.value(at: rulesPath) {
            if case .array = value, let lines = LinkRouting.lines(value) {
                for line in lines {
                    if let rule = TerminalLinkOpenerRule(line) {
                        setting.rules.append(rule)
                    } else {
                        diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: rulesPath.joined(separator: "."),
                                                              message: "expected <match> -> <target>, such as caller:aws -> chrome"))
                    }
                }
            } else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: rulesPath.joined(separator: "."), message: "expected an array of strings"))
            }
        }
        return (setting, diagnostics)
    }
}
