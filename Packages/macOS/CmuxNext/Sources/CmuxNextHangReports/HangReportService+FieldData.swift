import CmuxNextMetrics
import Foundation

extension HangReportService {
    /// What a report's field data is read from, and the earlier launches it carries.
    struct FieldData {
        /// The builder's input; nil when the schema has no field data.
        var input: HangReportBuilder.FieldDataInput?
        /// The earlier launches in ``input``, by their files.
        var sections: [MetricsLaunchSection<MetricsLaunchContents>] = []

        /// Whether a report should go for it alone (a black box alone is context, not a finding).
        var hasContent: Bool { input?.current != nil || !sections.isEmpty }
    }

    /// What a queued report's field data marks sent once the server took it.
    struct FieldCommit {
        /// The part of the current delta the report carries (``HangReportBuilder/sentDelta(_:histograms:)``).
        var sent: MetricsDelta?
        /// The earlier launches the report carries; their files are deleted.
        var sections: [MetricsLaunchSection<MetricsLaunchContents>]

        /// What `report`, built from `field`, carries; nil when it carries no field data. What the body cap cut stays
        /// for a later report.
        init?(_ field: FieldData, sentIn report: HangReport) {
            sent = field.input?.current.map { HangReportBuilder.sentDelta($0, histograms: report.histograms ?? []) }
            let kept = Set((report.launchSections ?? []).map(\.id))
            sections = field.sections.filter { kept.contains(HangReportBuilder.sectionID($0.id)) }
            if sent == nil, sections.isEmpty { return nil }
        }
    }

    /// The report id of an outbox entry (its file is `<report id>.json`).
    static func reportID(of entry: URL) -> String {
        entry.deletingPathExtension().lastPathComponent
    }
}
