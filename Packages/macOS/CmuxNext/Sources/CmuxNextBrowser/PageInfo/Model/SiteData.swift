import Foundation

/// One site (registrable domain) that stored data while the page was open.
public nonisolated struct SiteDataEntry: Hashable, Sendable, Identifiable {
    public var domain: String
    public var cookieCount: Int
    /// Local storage, IndexedDB, caches and similar (not cookies).
    public var hasOtherData: Bool
    public var isThirdParty: Bool

    public var id: String { domain }

    public init(domain: String, cookieCount: Int, hasOtherData: Bool = false, isThirdParty: Bool) {
        self.domain = domain
        self.cookieCount = cookieCount
        self.hasOtherData = hasOtherData
        self.isThirdParty = isThirdParty
    }
}

/// How the engine treats third-party cookies. Chrome shows the cookies
/// subpage's third-party section only when they are blocked.
public nonisolated enum ThirdPartyCookiePolicy: Hashable, Sendable {
    case allowed
    /// Blocked by the engine, not changeable per site (WebKit ITP).
    case blocked
}

/// The cookies subpage and the "On-device site data" dialog.
public nonisolated struct SiteDataSummary: Hashable, Sendable {
    public var entries: [SiteDataEntry]
    public var thirdPartyPolicy: ThirdPartyCookiePolicy

    public init(entries: [SiteDataEntry] = [], thirdPartyPolicy: ThirdPartyCookiePolicy = .allowed) {
        self.entries = entries.sorted { ($0.isThirdParty ? 1 : 0, $0.domain) < ($1.isThirdParty ? 1 : 0, $1.domain) }
        self.thirdPartyPolicy = thirdPartyPolicy
    }

    public var firstPartyCookies: Int { entries.filter { !$0.isThirdParty }.reduce(0) { $0 + $1.cookieCount } }
    public var thirdPartySites: [SiteDataEntry] { entries.filter(\.isThirdParty) }
    public var siteCount: Int { entries.count }

    /// Groups cookie domains (".cdn.example.com", "example.com") into sites
    /// relative to the page's `host`.
    public static func grouping(cookieDomains: [String], otherDataDomains: [String] = [], pageHost: String?,
                                thirdPartyPolicy: ThirdPartyCookiePolicy) -> SiteDataSummary {
        let pageSite = pageHost.map(SiteDomain.registrable)
        var counts: [String: Int] = [:]
        for domain in cookieDomains { counts[SiteDomain.registrable(domain), default: 0] += 1 }
        let other = Set(otherDataDomains.map(SiteDomain.registrable))
        let sites = Set(counts.keys).union(other)
        let entries = sites.map { site in
            SiteDataEntry(domain: site, cookieCount: counts[site] ?? 0, hasOtherData: other.contains(site), isThirdParty: site != pageSite)
        }
        return SiteDataSummary(entries: entries, thirdPartyPolicy: thirdPartyPolicy)
    }
}
