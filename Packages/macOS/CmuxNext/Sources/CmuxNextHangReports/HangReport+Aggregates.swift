extension HangReport {
    /// This report as aggregate performance data sends it (`diagnostics.performanceData`, ``HangReportService/Mode/aggregates``),
    /// by allow-list: the envelope, the catalog histograms and the stability counts, this launch's and earlier
    /// launches' (each section is an earlier launch's histograms and stability counts under its profile). No hang or
    /// blocking sample, CPU exception, black box, MetricKit metric, interval, launch timing, input latency, active
    /// time, feature or blocking site, as Chrome's UMA upload carries histograms and stability counts under a system
    /// profile (components/metrics/metrics_log.cc).
    public var aggregatesOnly: HangReport {
        var report = HangReport(reportId: reportId, installId: installId, day: day, app: app, os: os, hardware: hardware, counts: counts)
        report.schema = schema
        report.histograms = histograms
        report.stability = stability
        report.launchSections = launchSections
        return report
    }

    /// Whether the report holds nothing ``aggregatesOnly`` leaves out.
    public var isAggregatesOnly: Bool { self == aggregatesOnly }
}
