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
/// The default sends sites whose protected (DRM) media does not play in cmux's Chromium to WebKit:
/// the Chromium build has no Widevine CDM that installs, no H.264/AAC (`proprietary_codecs`) and
/// no VMP signing (plans/cmux-next/browser.md, open question 6). Setting the key replaces the
/// whole list, so a person can remove a default site.
public nonisolated struct BrowserSiteEngines: Sendable, Hashable {
    /// Normalized pattern (lowercase host, optional `/path`) to engine.
    public let rules: [String: BrowserDefaultEngine]

    public static let configPath = ["browser", "siteEngines"]

    /// Sites whose protected media needs WebKit (FairPlay) in cmux. `music.youtube.com` is not
    /// here: it plays in Chromium unless shown otherwise.
    public static let protectedMediaSites = [
        "spotify.com", "netflix.com", "disneyplus.com", "max.com", "hulu.com", "primevideo.com",
        "amazon.com/gp/video", "tv.apple.com", "music.apple.com",
    ]

    /// Every protected-media site on WebKit.
    public static let fallback = BrowserSiteEngines(rules: Dictionary(uniqueKeysWithValues: protectedMediaSites.map { ($0, .webkit) }))

    /// - Parameter rules: Site pattern to engine; patterns are normalized (lowercase, no scheme,
    ///   no `*.`, no trailing `/`), and one that is empty after that is dropped.
    public init(rules: [String: BrowserDefaultEngine]) {
        var normalized: [String: BrowserDefaultEngine] = [:]
        for (pattern, engine) in rules {
            guard let key = Self.normalize(pattern) else { continue }
            normalized[key] = engine
        }
        self.rules = normalized
    }

    /// The engine the most specific rule gives `url`, nil when no rule matches (the default
    /// engine decides).
    ///
    /// - Parameter url: The page a tab opens.
    /// - Returns: The rule's engine, or nil.
    public func engine(for url: URL?) -> BrowserDefaultEngine? {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = url.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        let path = url.path.isEmpty ? "/" : url.path.lowercased()
        var best: (hostLength: Int, pathLength: Int, engine: BrowserDefaultEngine)?
        for (pattern, engine) in rules {
            let (patternHost, patternPath) = Self.split(pattern)
            guard host == patternHost || host.hasSuffix("." + patternHost) else { continue }
            if let patternPath {
                guard path == patternPath || path.hasPrefix(patternPath + "/") else { continue }
            }
            let rank = (patternHost.count, patternPath?.count ?? 0)
            if let current = best, (current.hostLength, current.pathLength) >= rank { continue }
            best = (rank.0, rank.1, engine)
        }
        return best?.engine
    }

    /// The value cmux.json holds for these rules.
    public var jsonValue: JSONValue {
        .object(rules.mapValues { .string($0.rawValue) })
    }

    /// Parses the `browser` section. A missing key is the default with no diagnostic; a value
    /// that is not an object is the default plus a diagnostic; an entry whose engine is not
    /// `chromium` or `webkit` is left out, with a diagnostic.
    static func parse(_ root: JSONValue) -> (BrowserSiteEngines, [SettingsDiagnostic]) {
        guard case .object(let browser)? = root["browser"], let value = browser["siteEngines"] else { return (fallback, []) }
        guard case .object(let members) = value else {
            return (fallback, [SettingsDiagnostic(kind: .invalidValue, path: "browser.siteEngines",
                                                  message: "expected an object of site to \"chromium\" or \"webkit\"")])
        }
        var rules: [String: BrowserDefaultEngine] = [:]
        var diagnostics: [SettingsDiagnostic] = []
        for (pattern, engine) in members {
            guard let text = engine.stringValue, let engine = BrowserDefaultEngine(rawValue: text), normalize(pattern) != nil else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "browser.siteEngines",
                                                      message: "\(pattern): expected a site and \"chromium\" or \"webkit\""))
                continue
            }
            rules[pattern] = engine
        }
        return (BrowserSiteEngines(rules: rules), diagnostics)
    }

    /// `HTTPS://*.Open.Spotify.com/` is `open.spotify.com`; nil for an empty pattern or one with
    /// no host.
    static func normalize(_ pattern: String) -> String? {
        var text = pattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let scheme = text.range(of: "://") { text = String(text[scheme.upperBound...]) }
        if text.hasPrefix("*.") { text.removeFirst(2) }
        while text.hasSuffix("/") { text.removeLast() }
        let (host, _) = split(text)
        guard !host.isEmpty, !host.contains(" ") else { return nil }
        return text
    }

    /// The host and the path prefix (`/gp/video`, nil for none) of a normalized pattern.
    private static func split(_ pattern: String) -> (host: String, path: String?) {
        guard let slash = pattern.firstIndex(of: "/") else { return (pattern, nil) }
        let path = String(pattern[slash...])
        return (String(pattern[..<slash]), path == "/" ? nil : path)
    }
}
