import CmuxNextCompat

/// The `blocking_sites` part of a report (p12-perf-process-226): the main thread's blocking call counts by hashed
/// site id, kind, count and milliseconds only.
extension HangReportBuilder {
    /// The site id pattern: ``HangReport/BlockingSiteCount/siteID(location:)``'s 16 lowercase hex digits.
    static let blockingSitePattern = #"^[0-9a-f]{16}$"#
    /// The most calls or milliseconds one site may say (a larger value is sent as this).
    static let maxBlockingSiteValue = 1_000_000_000

    /// Sets `blocking_sites` from `sites`: only the entries whose id is a site id, whose kind is a `BlockingKind`
    /// and that counted a call, at most ``HangReport/maxBlockingSites``, most calls first; nil when none is left.
    static func addBlockingSites(_ sites: [HangReport.BlockingSiteCount], to report: inout HangReport) {
        let kinds = Set(BlockingKind.allCases.map(\.rawValue))
        let kept = sites.filter { site in
            site.count > 0 && kinds.contains(site.kind)
                && site.site.range(of: blockingSitePattern, options: .regularExpression) != nil
        }.map { site in
            HangReport.BlockingSiteCount(site: site.site, kind: site.kind, count: min(site.count, maxBlockingSiteValue),
                                         totalMs: min(max(0, site.totalMs), maxBlockingSiteValue))
        }.sorted { ($0.count, $0.totalMs, $1.site) > ($1.count, $1.totalMs, $0.site) }
        report.blockingSites = kept.isEmpty ? nil : Array(kept.prefix(HangReport.maxBlockingSites))
    }
}
