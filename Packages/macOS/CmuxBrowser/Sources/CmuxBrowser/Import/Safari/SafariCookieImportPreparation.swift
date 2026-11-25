public import Foundation

/// Turns decoded Safari cookie records into the `HTTPCookie` values an import writes.
///
/// Records without a name or outside the domain filters are dropped without
/// being counted. Records that had expired by `date` are dropped and counted,
/// so the importer can report them as skipped.
///
/// ```swift
/// let preparation = SafariCookieImportPreparation(domainFilters: ["example.com"], date: Date())
/// let prepared = preparation.prepare(try SafariBinaryCookiesParser().parse(data))
/// ```
public struct SafariCookieImportPreparation {
    private let domainFilter: BrowserImportDomainFilter
    private let date: Date

    /// Creates a preparation step for one import.
    ///
    /// - Parameters:
    ///   - domainFilters: Domains as `BrowserDataImporter.parseDomainFilters`
    ///     produces them; an empty list keeps every domain.
    ///   - date: The moment expiry is judged against.
    public init(domainFilters: [String], date: Date) {
        self.domainFilter = BrowserImportDomainFilter(filters: domainFilters)
        self.date = date
    }

    /// Filters `records` and converts the ones to import.
    public func prepare(_ records: [SafariBinaryCookie]) -> SafariPreparedCookies {
        var cookies: [HTTPCookie] = []
        var expiredCount = 0
        for record in records {
            guard !record.name.isEmpty else { continue }
            guard domainFilter.matches(host: record.domain) else { continue }
            if record.isExpired(at: date) {
                expiredCount += 1
                continue
            }
            if let cookie = Self.httpCookie(from: record) {
                cookies.append(cookie)
            }
        }
        return SafariPreparedCookies(cookies: cookies, expiredCount: expiredCount)
    }

    /// The `HTTPCookie` for `record`, with an empty path stored as `/`, or `nil` when Foundation rejects the properties.
    private static func httpCookie(from record: SafariBinaryCookie) -> HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .domain: record.domain,
            .path: record.path.isEmpty ? "/" : record.path,
            .name: record.name,
            .value: record.value,
        ]
        if record.isSecure {
            properties[.secure] = "TRUE"
        }
        if record.isHTTPOnly {
            // Foundation reads this key for `isHTTPOnly` but does not publish a
            // constant for it; a system that ignores it still imports the cookie.
            properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE"
        }
        switch record.sameSite {
        case .lax:
            properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteLax.rawValue
        case .strict:
            properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteStrict.rawValue
        case nil:
            break
        }
        if let expiresDate = record.expiresDate {
            properties[.expires] = expiresDate
        }
        return HTTPCookie(properties: properties)
    }
}
