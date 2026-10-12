public import Foundation

/// Where a web link clicked in a terminal opens, from classic cmux's keys in
/// cmux.json (same names, so a classic `cmux.json` keeps working):
///
/// ```jsonc
/// "browser": {
///   "openTerminalLinksInCmuxBrowser": true,             // false: every link opens in the default browser
///   "hostsToOpenInEmbeddedBrowser": ["*.example.com"],  // empty: every host opens in cmux
///   "urlsToAlwaysOpenExternally": ["re:^https://[^/]*\\.example\\.com/billing"]
/// }
/// ```
///
/// External rules match as classic matched them (`BrowserExternalURLPatternMatcher`):
/// plain text is a substring, `*`/`?` are wildcards, `re:` is a bounded regex.
public nonisolated struct TerminalLinkRouting: Sendable, Hashable {
    public var opensInCmuxBrowser: Bool
    public var embeddedHosts: [String]
    public var externalRules: [String]

    public static let fallback = TerminalLinkRouting(opensInCmuxBrowser: true, embeddedHosts: [], externalRules: [])

    public init(opensInCmuxBrowser: Bool, embeddedHosts: [String], externalRules: [String]) {
        self.opensInCmuxBrowser = opensInCmuxBrowser
        self.embeddedHosts = embeddedHosts
        self.externalRules = externalRules
    }

    static let openPath = ["browser", "openTerminalLinksInCmuxBrowser"]
    static let hostsPath = ["browser", "hostsToOpenInEmbeddedBrowser"]
    static let rulesPath = ["browser", "urlsToAlwaysOpenExternally"]

    /// True when this http(s) link opens in a cmux browser tab, false when it
    /// goes to the default browser: the setting is off (unless `explicit`, a
    /// click that picked a cmux browser profile), an external rule matches,
    /// the host is unusable, or the host list is set and misses the host.
    public func opensInCmux(_ url: URL, explicit: Bool = false) -> Bool {
        guard opensInCmuxBrowser || explicit else { return false }
        if !externalRules.isEmpty, BrowserExternalURLPatternMatcher(patterns: externalRules).matches(url.absoluteString) {
            return false
        }
        guard let host = Self.normalizedHost(url.host ?? "") else { return false }
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

    static func parse(_ root: JSONValue) -> (TerminalLinkRouting, [SettingsDiagnostic]) {
        var setting = fallback
        var diagnostics: [SettingsDiagnostic] = []
        guard case .object(let browser)? = root["browser"] else { return (setting, diagnostics) }
        if let value = browser[openPath[1]] {
            if let flag = value.boolValue {
                setting.opensInCmuxBrowser = flag
            } else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: openPath.joined(separator: "."), message: "expected true or false"))
            }
        }
        for (path, field) in [(hostsPath, \TerminalLinkRouting.embeddedHosts), (rulesPath, \.externalRules)] {
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
