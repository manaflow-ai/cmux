import Foundation

/// Decides whether a cookie or history host falls under an import's domain filters.
///
/// Build one per import from the parsed filters, then call ``matches(host:)``
/// for each record. A host matches when it equals a filter or ends with `.`
/// followed by one, so `example.com` covers `login.example.com` but not
/// `notexample.com`. An empty filter list matches every host.
///
/// The filters are held in a set, and each host is checked by looking up the
/// host and every suffix that starts after one of its dots. The cost per host
/// depends on the host's length, not on how many filters there are.
///
/// ```swift
/// let filter = BrowserImportDomainFilter(filters: ["example.com"])
/// filter.matches(host: ".login.example.com") // true
/// ```
public struct BrowserImportDomainFilter: Sendable {
    private let filters: Set<String>

    /// Creates a filter.
    ///
    /// - Parameter filters: Domains as `BrowserDataImporter.parseDomainFilters`
    ///   produces them: lowercased, without a leading `*.` or `.`.
    public init(filters: [String]) {
        self.filters = Set(filters)
    }

    /// Whether `host` is one of the filtered domains or a subdomain of one.
    ///
    /// The host is trimmed, lowercased and stripped of leading dots first, as
    /// cookie domains are often stored as `.example.com`.
    public func matches(host: String) -> Bool {
        guard !filters.isEmpty else { return true }
        var normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while normalizedHost.hasPrefix(".") {
            normalizedHost.removeFirst()
        }
        guard !normalizedHost.isEmpty else { return false }

        var candidate = Substring(normalizedHost)
        while true {
            if filters.contains(String(candidate)) {
                return true
            }
            guard let dot = candidate.firstIndex(of: ".") else {
                return false
            }
            candidate = candidate[candidate.index(after: dot)...]
        }
    }
}
