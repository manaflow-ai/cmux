public import Foundation

/// Where a web link opens, for every surface that opens one (terminals, agent chats, the Home
/// transcript, cmux pages, the Help menu, update notes, the feed), from cmux.json:
///
/// ```jsonc
/// "browser": {
///   "openLinksInCmuxBrowser": true,                     // false: every link opens in the default browser
///   "hostsToOpenInEmbeddedBrowser": ["*.example.com"],  // empty: every host opens in cmux
///   "urlsToAlwaysOpenExternally": ["re:^https://[^/]*\\.example\\.com/billing"],
///   "openSignInPagesInCmux": true,                      // false: sign-in pages follow the keys above
///   "openPullRequestsInGitHubPage": false               // true: a chat's pull request link opens the cmux GitHub page
/// }
/// ```
///
/// `browser.openTerminalLinksInCmuxBrowser`, classic cmux's name for the first key, is still read
/// when `openLinksInCmuxBrowser` is absent (a classic `cmux.json`, an MDM profile written for it);
/// the new key wins when both are set, and Settings writes only the new key. External rules
/// match as classic matched them (`BrowserExternalURLPatternMatcher`): plain text is a
/// substring, `*`/`?` are wildcards, `re:` is a bounded regex.
///
/// `browser.enabled` (classic's Disable cmux Browser switch, on by default) turns the cmux browser
/// off: every link goes to the system whatever the other keys, and no browser tab opens for a web
/// page (``browserEnabled``).
///
/// `browser.openSignInPagesInCmux` (on by default, ``signInPagesInCmux``): a sign-in or
/// device-code page (``SignInPage``) opens in a cmux browser tab even when the toggle is off or
/// the host list misses its host; an external rule still sends it out.
///
/// `browser.openPullRequestsInGitHubPage` (off by default, ``pullRequestsInGitHubPage``): a GitHub pull
/// request link clicked in an agent chat opens its github.com page in a cmux tab; on, the cmux GitHub page.
public nonisolated struct LinkRouting: Sendable, Hashable {
    public var opensInCmuxBrowser: Bool
    public var embeddedHosts: [String]
    public var externalRules: [String]
    /// `browser.enabled`: false turns the cmux browser off (no web browser tab, every link to the system).
    public var browserEnabled: Bool
    /// `browser.openSignInPagesInCmux`: true opens every ``SignInPage`` in a cmux browser tab unless an
    /// external rule matches it; false leaves sign-in pages to the other keys like any link.
    public var signInPagesInCmux: Bool
    /// `browser.openPullRequestsInGitHubPage`: true opens a chat's pull request link in the cmux GitHub
    /// page (CmuxNextGitHubViewer's `GitHubLink.page(for:routing:)`), false on github.com.
    public var pullRequestsInGitHubPage: Bool

    /// Every key's default: schemas/settings/source/browser.json (SettingsSchema+Browser.generated.swift),
    /// which also has each key's path (`openPath`, `enabledPath`, `signInPagesPath`,
    /// `pullRequestsInGitHubPagePath`, `legacyOpenPath`, `hostsPath`, `rulesPath`).
    public static let fallback = LinkRouting(opensInCmuxBrowser: openDefault, embeddedHosts: hostsDefault, externalRules: rulesDefault)

    public init(opensInCmuxBrowser: Bool, embeddedHosts: [String], externalRules: [String], browserEnabled: Bool = LinkRouting.enabledDefault,
                signInPagesInCmux: Bool = LinkRouting.signInPagesDefault,
                pullRequestsInGitHubPage: Bool = LinkRouting.pullRequestsInGitHubPageDefault) {
        self.opensInCmuxBrowser = opensInCmuxBrowser
        self.embeddedHosts = embeddedHosts
        self.externalRules = externalRules
        self.browserEnabled = browserEnabled
        self.signInPagesInCmux = signInPagesInCmux
        self.pullRequestsInGitHubPage = pullRequestsInGitHubPage
    }

    /// Where one link goes.
    public enum Target: String, Sendable, Hashable {
        /// A cmux browser tab.
        case cmuxBrowser
        /// The system: the default browser for a web link, the scheme's app for any other.
        case system
    }

    /// Where `url` opens. Only an http(s) link can open in cmux. `otherTarget` (Shift-Command
    /// on a click) asks for the target the setting does not pick: a link the rules send out
    /// opens in cmux, and one they keep in cmux opens in the default browser. `explicit` is a
    /// click that picked a cmux browser profile (the toggle does not apply, the rules do).
    /// Rust answers (`link_rules.target`).
    public func target(for url: URL, otherTarget: Bool = false, explicit: Bool = false) -> Target {
        var request = linkRequest(url, explicit: explicit)
        request["otherTarget"] = .bool(otherTarget)
        let reply = SettingsRust.answer("link_rules.target", .object(request))
        return reply["target"]?.stringValue.flatMap(Target.init(rawValue:)) ?? .system
    }

    /// True when this http(s) link opens in a cmux browser tab, false when it
    /// goes to the default browser: the cmux browser is off, an external rule matches, the host is
    /// unusable, or, for a link that is not a sign-in page kept in cmux (``keepsSignInPageInCmux(_:)``),
    /// the setting is off (unless `explicit`, a click that picked a cmux browser profile) or the
    /// host list is set and misses the host. Rust answers (`link_rules.opens_in_cmux`, cmux-config
    /// `link_rules`: classic's host normalizer and `urlsToAlwaysOpenExternally` matcher).
    public func opensInCmux(_ url: URL, explicit: Bool = false) -> Bool {
        let reply = SettingsRust.answer("link_rules.opens_in_cmux", .object(linkRequest(url, explicit: explicit)))
        return reply["opensInCmux"]?.boolValue ?? false
    }

    /// Whether `url` is a ``SignInPage`` that ``signInPagesInCmux`` keeps in a cmux browser tab
    /// (the cmux browser is on). An external rule still wins (``opensInCmux(_:explicit:)``).
    public func keepsSignInPageInCmux(_ url: URL) -> Bool {
        browserEnabled && signInPagesInCmux && SignInPage(url: url) != nil
    }

    /// The link ops' request for `url`: Foundation splits it, and ``SignInPage`` says whether it
    /// is a sign-in page.
    func linkRequest(_ url: URL, explicit: Bool = false) -> [String: JSONValue] {
        [
            "routing": jsonValue,
            "url": .string(url.absoluteString),
            "scheme": .string(url.scheme ?? ""),
            "host": .string(url.host ?? ""),
            "signInPage": .bool(SignInPage(url: url) != nil),
            "explicit": .bool(explicit),
        ]
    }

    /// The setting as the link ops read it (cmux-config `link_rules::Routing::from_json`).
    var jsonValue: JSONValue {
        .object([
            "opensInCmuxBrowser": .bool(opensInCmuxBrowser),
            "embeddedHosts": .array(embeddedHosts.map(JSONValue.string)),
            "externalRules": .array(externalRules.map(JSONValue.string)),
            "browserEnabled": .bool(browserEnabled),
            "signInPagesInCmux": .bool(signInPagesInCmux),
            "pullRequestsInGitHubPage": .bool(pullRequestsInGitHubPage),
        ])
    }

    /// Rust reads the keys and their diagnostics (`link_rules.routing`).
    static func parse(_ root: JSONValue) -> (LinkRouting, [SettingsDiagnostic]) {
        let reply = SettingsRust.answer("link_rules.routing", .object(["root": root]))
        guard let routing = reply["routing"]?.objectValue else { return (fallback, []) }
        let strings = { (key: String) in routing[key]?.arrayValue?.compactMap(\.stringValue) }
        let setting = LinkRouting(
            opensInCmuxBrowser: routing["opensInCmuxBrowser"]?.boolValue ?? openDefault,
            embeddedHosts: strings("embeddedHosts") ?? hostsDefault,
            externalRules: strings("externalRules") ?? rulesDefault,
            browserEnabled: routing["browserEnabled"]?.boolValue ?? enabledDefault,
            signInPagesInCmux: routing["signInPagesInCmux"]?.boolValue ?? signInPagesDefault,
            pullRequestsInGitHubPage: routing["pullRequestsInGitHubPage"]?.boolValue ?? pullRequestsInGitHubPageDefault)
        return (setting, linkDiagnostics(reply))
    }

    /// A link op's `problems` (`[{path, message}]`) as diagnostics.
    static func linkDiagnostics(_ reply: JSONValue) -> [SettingsDiagnostic] {
        (reply["problems"]?.arrayValue ?? []).compactMap { problem in
            guard let path = problem["path"]?.stringValue, let message = problem["message"]?.stringValue else { return nil }
            return SettingsDiagnostic(kind: .invalidValue, path: path, message: message)
        }
    }

    /// An array of strings, or classic's one-per-line text; blank lines and `#` comments dropped.
    /// Kept for the classic preferences import (``ClassicPreferenceImport``); the cmux.json keys are
    /// read by Rust (`link_rules::lines`).
    static func lines(_ value: JSONValue) -> [String]? {
        let texts: [String]
        switch value {
        case .string(let text): texts = [text]
        case .array(let items):
            guard items.allSatisfy({ $0.stringValue != nil }) else { return nil }
            texts = items.compactMap(\.stringValue)
        default: return nil
        }
        return texts.flatMap { $0.components(separatedBy: .newlines) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }
}
