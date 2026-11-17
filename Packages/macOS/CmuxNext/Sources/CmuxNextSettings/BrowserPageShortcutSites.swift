public import Foundation

/// `browser.pageShortcutSites` in cmux.json: sites with their own answer to who gets a shortcut that cmux and the
/// page both use (CMUX-641, Lucas 2026-11-18: "this needs to ask per-web page"). One object of site to `page` or
/// `cmux`; the page shortcuts dialog adds an entry for the site it asked about:
///
/// ```json
/// "browser": { "pageShortcutSites": { "linear.app": "page", "docs.google.com": "cmux" } }
/// ```
///
/// A site matches itself and its subdomains, and the most specific match wins. A site with no entry follows
/// `browser.pageShortcuts` (``CmuxConfigSnapshot/pageShortcuts(forHost:)``).
public nonisolated struct BrowserPageShortcutSites: Sendable, Hashable {
    /// Lowercased site (no scheme, no `*.`) to its answer: `page` or `cmux`, never `ask`.
    public let rules: [String: BrowserPageShortcuts]

    public static let fallback = BrowserPageShortcutSites(rules: [:])

    /// - Parameter rules: Site to answer; a site that is empty after normalizing, and an `ask`, are dropped.
    public init(rules: [String: BrowserPageShortcuts]) {
        var normalized: [String: BrowserPageShortcuts] = [:]
        for (site, mode) in rules where mode != .ask {
            if let site = Self.site(site) { normalized[site] = mode }
        }
        self.rules = normalized
    }

    /// The answer of the most specific site that matches `host`, nil when none does: `host`, then each parent
    /// domain, so a key costs a lookup per label, not a pass over every site.
    public func mode(forHost host: String?) -> BrowserPageShortcuts? {
        guard let labels = host.flatMap(Self.site)?.split(separator: ".") else { return nil }
        for start in labels.indices {
            if let mode = rules[labels[start...].joined(separator: ".")] { return mode }
        }
        return nil
    }

    /// These sites with `host` answering `mode`, as cmux.json holds them.
    public func setting(_ mode: BrowserPageShortcuts, forHost host: String) -> JSONValue {
        var rules = rules
        // The dialog saves the site without `www.`, so it covers the site's other names too.
        if var site = Self.site(host) {
            if site.hasPrefix("www."), site.count > 4 { site.removeFirst(4) }
            rules[site] = mode
        }
        return BrowserPageShortcutSites(rules: rules).jsonValue
    }

    /// The value cmux.json holds for these sites.
    public var jsonValue: JSONValue {
        .object(rules.mapValues { .string($0.rawValue) })
    }

    /// Parses the `browser` section. A missing key is no sites; a value that is not an object, and an entry that is not
    /// a site with `page` or `cmux`, are left out with a diagnostic.
    static func parse(_ root: JSONValue) -> (BrowserPageShortcutSites, [SettingsDiagnostic]) {
        guard case .object(let browser)? = root["browser"], let value = browser["pageShortcutSites"] else { return (fallback, []) }
        guard case .object(let members) = value else {
            return (fallback, [SettingsDiagnostic(kind: .invalidValue, path: "browser.pageShortcutSites",
                                                  message: "expected an object of site to \"page\" or \"cmux\"")])
        }
        var rules: [String: BrowserPageShortcuts] = [:]
        var diagnostics: [SettingsDiagnostic] = []
        for (site, value) in members {
            guard let text = value.stringValue, let mode = BrowserPageShortcuts(rawValue: text), mode != .ask, Self.site(site) != nil else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "browser.pageShortcutSites",
                                                      message: "\(site): expected a site and \"page\" or \"cmux\""))
                continue
            }
            rules[site] = mode
        }
        return (BrowserPageShortcutSites(rules: rules), diagnostics)
    }

    /// `HTTPS://*.Linear.app/` is `linear.app` (`www.` stays: it can have its own answer); nil for an empty site or one
    /// with a space.
    static func site(_ text: String) -> String? {
        var site = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let scheme = site.range(of: "://") { site = String(site[scheme.upperBound...]) }
        if let slash = site.firstIndex(of: "/") { site = String(site[..<slash]) }
        if site.hasPrefix("*.") { site.removeFirst(2) }
        if site.hasSuffix(".") { site.removeLast() }
        guard !site.isEmpty, !site.contains(" ") else { return nil }
        return site
    }
}

extension CmuxConfigSnapshot {
    /// Who gets a shared shortcut on a page of `host`: its `browser.pageShortcutSites` answer, else
    /// `browser.pageShortcuts`.
    public func pageShortcuts(forHost host: String?) -> BrowserPageShortcuts {
        browserPageShortcutSites.mode(forHost: host) ?? browserPageShortcuts
    }
}
