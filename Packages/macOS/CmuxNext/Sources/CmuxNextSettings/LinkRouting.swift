public import Foundation

/// Where a web link opens, for every surface that opens one (terminals, agent chats, the Home
/// transcript, cmux pages, the Help menu, update notes, the feed), from cmux.json:
///
/// ```jsonc
/// "browser": {
///   "openLinksInCmuxBrowser": true,                     // false: every link opens in the default browser
///   "hostsToOpenInEmbeddedBrowser": ["*.example.com"],  // empty: every host opens in cmux
///   "urlsToAlwaysOpenExternally": ["re:^https://[^/]*\\.example\\.com/billing"],
///   "openSignInPagesInCmux": true                       // false: sign-in pages follow the keys above
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
public nonisolated struct LinkRouting: Sendable, Hashable {
    public var opensInCmuxBrowser: Bool
    public var embeddedHosts: [String]
    public var externalRules: [String]
    /// `browser.enabled`: false turns the cmux browser off (no web browser tab, every link to the system).
    public var browserEnabled: Bool
    /// `browser.openSignInPagesInCmux`: true opens every ``SignInPage`` in a cmux browser tab unless an
    /// external rule matches it; false leaves sign-in pages to the other keys like any link.
    public var signInPagesInCmux: Bool

    public static let fallback = LinkRouting(opensInCmuxBrowser: true, embeddedHosts: [], externalRules: [])

    public init(opensInCmuxBrowser: Bool, embeddedHosts: [String], externalRules: [String], browserEnabled: Bool = true,
                signInPagesInCmux: Bool = true) {
        self.opensInCmuxBrowser = opensInCmuxBrowser
        self.embeddedHosts = embeddedHosts
        self.externalRules = externalRules
        self.browserEnabled = browserEnabled
        self.signInPagesInCmux = signInPagesInCmux
    }

    /// Where one link goes.
    public enum Target: String, Sendable, Hashable {
        /// A cmux browser tab.
        case cmuxBrowser
        /// The system: the default browser for a web link, the scheme's app for any other.
        case system
    }

    public static let openPath = ["browser", "openLinksInCmuxBrowser"]
    /// `browser.enabled`, the Settings row Enable cmux Browser.
    public static let enabledPath = ["browser", "enabled"]
    /// `browser.openSignInPagesInCmux`, the Settings row Open Sign-In Pages in cmux Browser.
    public static let signInPagesPath = ["browser", "openSignInPagesInCmux"]
    /// Classic's key, read when ``openPath`` is absent (``EffectiveSettings`` copies it over).
    public static let legacyOpenPath = ["browser", "openTerminalLinksInCmuxBrowser"]
    static let hostsPath = ["browser", "hostsToOpenInEmbeddedBrowser"]
    static let rulesPath = ["browser", "urlsToAlwaysOpenExternally"]

    /// Where `url` opens. Only an http(s) link can open in cmux. `otherTarget` (Shift-Command
    /// on a click) asks for the target the setting does not pick: a link the rules send out
    /// opens in cmux, and one they keep in cmux opens in the default browser. `explicit` is a
    /// click that picked a cmux browser profile (the toggle does not apply, the rules do).
    public func target(for url: URL, otherTarget: Bool = false, explicit: Bool = false) -> Target {
        let scheme = url.scheme?.lowercased()
        guard browserEnabled, scheme == "http" || scheme == "https" else { return .system }
        let cmux = opensInCmux(url, explicit: explicit)
        guard otherTarget else { return cmux ? .cmuxBrowser : .system }
        return cmux || Self.normalizedHost(url.host ?? "") == nil ? .system : .cmuxBrowser
    }

    /// True when this http(s) link opens in a cmux browser tab, false when it
    /// goes to the default browser: the cmux browser is off, an external rule matches, the host is
    /// unusable, or, for a link that is not a sign-in page kept in cmux (``keepsSignInPageInCmux(_:)``),
    /// the setting is off (unless `explicit`, a click that picked a cmux browser profile) or the
    /// host list is set and misses the host.
    public func opensInCmux(_ url: URL, explicit: Bool = false) -> Bool {
        guard browserEnabled else { return false }
        if !externalRules.isEmpty, BrowserExternalURLPatternMatcher(patterns: externalRules).matches(url.absoluteString) {
            return false
        }
        guard let host = Self.normalizedHost(url.host ?? "") else { return false }
        if keepsSignInPageInCmux(url) { return true }
        guard opensInCmuxBrowser || explicit else { return false }
        guard !embeddedHosts.isEmpty else { return true }
        return embeddedHosts.contains { raw in
            let pattern = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if pattern.hasPrefix("*.") {
                guard let suffix = Self.normalizedHost(String(pattern.dropFirst(2))) else { return false }
                return host == suffix || host.hasSuffix(".\(suffix)")
            }
            return Self.normalizedHost(pattern) == host
        }
    }

    /// Whether `url` is a ``SignInPage`` that ``signInPagesInCmux`` keeps in a cmux browser tab
    /// (the cmux browser is on). An external rule still wins (``opensInCmux(_:explicit:)``).
    public func keepsSignInPageInCmux(_ url: URL) -> Bool {
        browserEnabled && signInPagesInCmux && SignInPage(url: url) != nil
    }

    /// Classic's host normalizer (`RemoteLoopbackProxyAlias.normalizeHost`):
    /// lowercase, no scheme, path, port, brackets or outer dots, IDN as punycode.
    static func normalizedHost(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return nil }
        if let parsed = URL(string: value)?.host { return trimmedHost(parsed) }
        if let scheme = value.range(of: "://") { value = String(value[scheme.upperBound...]) }
        if let slash = value.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) { value = String(value[..<slash]) }
        if value.hasPrefix("[") {
            if let closing = value.firstIndex(of: "]") {
                value = String(value[value.index(after: value.startIndex)..<closing])
            } else {
                value.removeFirst()
            }
        } else if let colon = value.lastIndex(of: ":"), value[value.index(after: colon)...].allSatisfy(\.isNumber),
                  value.filter({ $0 == ":" }).count == 1 {
            value = String(value[..<colon])
        }
        return trimmedHost(value)
    }

    private static func trimmedHost(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !trimmed.isEmpty else { return nil }
        return URL(string: "https://\(trimmed)")?.host ?? trimmed
    }

    static func parse(_ root: JSONValue) -> (LinkRouting, [SettingsDiagnostic]) {
        var setting = fallback
        var diagnostics: [SettingsDiagnostic] = []
        guard case .object(let browser)? = root["browser"] else { return (setting, diagnostics) }
        if let value = browser[enabledPath[1]] {
            if let flag = value.boolValue {
                setting.browserEnabled = flag
            } else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: enabledPath.joined(separator: "."), message: "expected true or false"))
            }
        }
        if let value = browser[signInPagesPath[1]] {
            if let flag = value.boolValue {
                setting.signInPagesInCmux = flag
            } else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: signInPagesPath.joined(separator: "."), message: "expected true or false"))
            }
        }
        // The new key wins; classic's is read only without it.
        let path = browser[openPath[1]] != nil ? openPath : legacyOpenPath
        if let value = browser[path[1]] {
            if let flag = value.boolValue {
                setting.opensInCmuxBrowser = flag
            } else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: path.joined(separator: "."), message: "expected true or false"))
            }
        }
        for (path, field) in [(hostsPath, \LinkRouting.embeddedHosts), (rulesPath, \.externalRules)] {
            guard let value = browser[path[1]] else { continue }
            // An array, as the Settings rows accept; classic's line text is only in its preferences.
            if case .array = value, let lines = lines(value) {
                setting[keyPath: field] = lines
            } else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: path.joined(separator: "."), message: "expected an array of strings"))
            }
        }
        return (setting, diagnostics)
    }

    /// An array of strings, or classic's one-per-line text; blank lines and `#` comments dropped.
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
