public import Foundation

/// The sites a cookie import keeps (`cmux browser import-cookies --domain`).
///
/// A cookie is kept when a site would send it: its host is one of the
/// domains, a subdomain of one, or (a domain cookie such as `.example.com`)
/// a parent of one. So `--domain app.example.com` keeps `.example.com`
/// sign-in cookies too, and `--domain example.com` keeps `api.example.com`.
/// An empty filter keeps everything.
///
/// ```swift
/// let filter = CookieDomainFilter("github.com, linear.app")
/// filter.keeps(cookie) // true for ".github.com" and "gist.github.com"
/// ```
public struct CookieDomainFilter: Sendable, Equatable {
    /// Lowercased hosts, no scheme, port, path or leading dot.
    public let domains: [String]

    /// - Parameter domains: hosts or URLs; blanks are dropped.
    public init(_ domains: [String]) {
        var seen = Set<String>()
        self.domains = domains.compactMap(Self.host).filter { seen.insert($0).inserted }
    }

    /// Parses a comma- or space-separated list (the CLI's `--domain` value).
    public init(_ list: String) {
        self.init(list.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" }).map(String.init))
    }

    /// Whether the filter keeps every cookie.
    public var keepsAll: Bool { domains.isEmpty }

    /// Whether a site in the filter would send `cookie`.
    public func keeps(_ cookie: ImportedCookie) -> Bool {
        guard !keepsAll else { return true }
        let host = cookie.host.lowercased()
        let isDomainCookie = cookie.domain.hasPrefix(".")
        return domains.contains { domain in
            host == domain || host.hasSuffix("." + domain) || (isDomainCookie && domain.hasSuffix("." + host))
        }
    }

    /// `https://Example.com:443/x` → `example.com`; nil for a blank or a value with no host.
    static func host(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return nil }
        if text.contains("://"), let host = URL(string: text)?.host() { text = host }
        if let slash = text.firstIndex(of: "/") { text = String(text.prefix(upTo: slash)) }
        if let colon = text.firstIndex(of: ":") { text = String(text.prefix(upTo: colon)) }
        while text.hasPrefix(".") { text.removeFirst() }
        if text.hasPrefix("*.") { text.removeFirst(2) }
        return text.isEmpty ? nil : text
    }
}
