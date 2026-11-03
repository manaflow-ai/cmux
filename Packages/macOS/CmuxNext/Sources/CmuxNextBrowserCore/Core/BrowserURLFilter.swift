public import Foundation

/// An organization's URL blocklist and allowlist in Chrome's filter format
/// (Chrome's `URLBlocklist` / `URLAllowlist` policies, support.google.com/chrome/a/answer/9942583):
/// `[scheme://][.]host[:port][/path][?query]`, `*` for every URL. A host
/// matches itself and its subdomains unless it starts with a dot; a path is
/// a prefix; query parameters must all be present. When a URL matches both
/// lists, the more specific filter wins (longer host, then longer path, then
/// more query parameters); on a tie the allowlist wins, as in Chrome.
/// cmux's own pages and `about:` are never blocked.
///
/// ```swift
/// let filter = BrowserURLFilter(blocklist: ["*"], allowlist: ["example.com"])
/// filter.blocks(URL(string: "https://www.example.com/a")!)  // false
/// filter.blocks(URL(string: "https://other.org")!)          // true
/// ```
public nonisolated struct BrowserURLFilter: Sendable, Hashable {
    /// No filter: every URL loads.
    public static let none = BrowserURLFilter(blocklist: [], allowlist: [])
    /// Chrome reads at most this many filters per list.
    public static let maximumFilters = 1000

    package let blocked: [BrowserURLFilterRule]
    package let allowed: [BrowserURLFilterRule]

    /// - Parameters:
    ///   - blocklist: Chrome `URLBlocklist` filters; an unreadable filter is ignored.
    ///   - allowlist: Chrome `URLAllowlist` filters, exceptions to the blocklist.
    public init(blocklist: [String], allowlist: [String]) {
        blocked = blocklist.prefix(Self.maximumFilters).compactMap(BrowserURLFilterRule.init(pattern:))
        allowed = allowlist.prefix(Self.maximumFilters).compactMap(BrowserURLFilterRule.init(pattern:))
    }

    /// True when no filter is set.
    public var isEmpty: Bool { blocked.isEmpty }

    /// Whether the organization blocks loading `url`.
    public func blocks(_ url: URL) -> Bool {
        guard !blocked.isEmpty, let scheme = url.scheme?.lowercased(), !Self.exemptSchemes.contains(scheme) else { return false }
        guard let block = blocked.filter({ $0.matches(url) }).map(\.specificity).max() else { return false }
        guard let allow = allowed.filter({ $0.matches(url) }).map(\.specificity).max() else { return true }
        return block > allow
    }

    /// cmux's own pages and blank pages, which a filter never blocks (Chrome
    /// exempts its internal pages the same way).
    package static let exemptSchemes: Set<String> = ["about", "cmux", "cmux-page"]
}
