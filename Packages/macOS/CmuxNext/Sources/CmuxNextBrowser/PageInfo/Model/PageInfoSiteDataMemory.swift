import Foundation

/// The bubble's last cookie summary per site, for its next opening on the same site.
///
/// The bubble reads a site's cookies again on every opening, so the Cookies page showed a
/// "Loading…" row each time, also for a site it read a moment ago. The pane's bubble keeps the
/// last summary per site here and draws it while the engine reads; the read replaces it.
/// Memory only, a few sites, counts only (no cookie names or values), gone with the pane.
struct PageInfoSiteDataMemory {
    /// The most sites kept; the one read longest ago goes first.
    let limit: Int
    /// The sites kept, the one read longest ago first.
    private var sites: [String] = []
    private var summaries: [String: SiteDataSummary] = [:]

    init(limit: Int = 32) {
        self.limit = limit
    }

    /// The summary last read for `site`; nil for a site not read yet and for a page that is no web site.
    func last(for site: PageInfoSite) -> SiteDataSummary? {
        Self.key(site).flatMap { summaries[$0] }
    }

    /// Keeps `data` as `site`'s summary for its next opening.
    mutating func remember(_ data: SiteDataSummary, for site: PageInfoSite) {
        guard let key = Self.key(site) else { return }
        sites.removeAll { $0 == key }
        sites.append(key)
        summaries[key] = data
        while sites.count > limit { summaries[sites.removeFirst()] = nil }
    }

    /// Forgets `site`'s summary (its data is being managed, so its counts can change): the next
    /// opening waits for the engine.
    mutating func forget(_ site: PageInfoSite) {
        guard let key = Self.key(site) else { return }
        sites.removeAll { $0 == key }
        summaries[key] = nil
    }

    private static func key(_ site: PageInfoSite) -> String? {
        site.isWeb ? site.displayName : nil
    }
}
