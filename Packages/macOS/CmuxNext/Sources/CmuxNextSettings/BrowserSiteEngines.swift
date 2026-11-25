public import Foundation

/// `browser.siteEngines` in cmux.json: sites that open in a set engine whatever
/// `browser.defaultEngine` says. One object of site pattern to engine:
///
/// ```json
/// "browser": { "siteEngines": { "spotify.com": "webkit", "amazon.com/gp/video": "webkit", "example.com": "chromium" } }
/// ```
///
/// A pattern is a host, optionally with a path prefix: `spotify.com` matches `spotify.com` and
/// every subdomain (`open.spotify.com`); `amazon.com/gp/video` matches only paths at or under
/// `/gp/video`. A leading `*.` and a scheme are ignored. The most specific pattern wins (the
/// longest host, then the longest path). Only `http` and `https` pages match.
///
/// The default is empty: protected (Widevine) media plays in cmux's Chromium (H.264/AAC from
/// `proprietary_codecs`, the component updater's CDM loaded by the plain helper,
/// plans/cmux-next/browser.md, open question 6). Setting the key replaces the whole list.
///
/// The rule itself is Rust's (cmux-config `site_engines`, through the `site_engines.*` ops), the
/// one copy the daemon's `browser_site_engines` asks too; Swift only hands it the URL's parts.
public nonisolated struct BrowserSiteEngines: Sendable, Hashable {
    /// Normalized pattern (lowercase host, optional `/path`) to engine.
    public let rules: [String: BrowserDefaultEngine]

    /// The default rules (none): `siteEnginesDefault`, from
    /// schemas/settings/source/browser.json (SettingsSchema+Browser.generated.swift).
    public static let fallback = BrowserSiteEngines(rules: Self.engines(siteEnginesDefault))

    /// - Parameter rules: Site pattern to engine; patterns are normalized (lowercase, no scheme,
    ///   no `*.`, no trailing `/`), and one that is empty after that is dropped.
    public init(rules: [String: BrowserDefaultEngine]) {
        let answer = SettingsRust.answer("site_engines.normalized", .object(["rules": Self.json(rules)]))
        self.rules = Self.engines(answer["rules"])
    }

    private init(normalized: [String: BrowserDefaultEngine]) {
        rules = normalized
    }

    /// The engine the most specific rule gives `url`, nil when no rule matches (the default
    /// engine decides).
    ///
    /// - Parameter url: The page a tab opens.
    /// - Returns: The rule's engine, or nil.
    public func engine(for url: URL?) -> BrowserDefaultEngine? {
        guard let url, let scheme = url.scheme, let host = url.host, !rules.isEmpty else { return nil }
        let answer = SettingsRust.answer("site_engines.engine", .object([
            "rules": jsonValue, "scheme": .string(scheme), "host": .string(host), "path": .string(url.path),
        ]))
        return answer["engine"]?.stringValue.flatMap(BrowserDefaultEngine.init(rawValue:))
    }

    /// The value cmux.json holds for these rules.
    public var jsonValue: JSONValue {
        Self.json(rules)
    }

    /// Parses the `browser` section. A missing key is the default with no diagnostic; a value
    /// that is not an object is the default plus a diagnostic; an entry whose engine is not
    /// `chromium` or `webkit` is left out, with a diagnostic.
    static func parse(_ root: JSONValue) -> (BrowserSiteEngines, [SettingsDiagnostic]) {
        let answer = SettingsRust.answer("site_engines.read", .object(["root": root]))
        let diagnostics = (answer["problems"]?.arrayValue ?? []).compactMap(\.stringValue).map {
            SettingsDiagnostic(kind: .invalidValue, path: "browser.siteEngines", message: $0)
        }
        guard let rules = answer["rules"]?.objectValue else { return (fallback, diagnostics) }
        return (BrowserSiteEngines(normalized: Self.engines(.object(rules))), diagnostics)
    }

    private static func json(_ rules: [String: BrowserDefaultEngine]) -> JSONValue {
        .object(rules.mapValues { .string($0.rawValue) })
    }

    private static func engines(_ value: JSONValue?) -> [String: BrowserDefaultEngine] {
        (value?.objectValue ?? [:]).compactMapValues { $0.stringValue.flatMap(BrowserDefaultEngine.init(rawValue:)) }
    }
}
