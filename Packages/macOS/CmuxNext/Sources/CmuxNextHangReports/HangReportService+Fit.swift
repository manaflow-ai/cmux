import Foundation

extension HangReportService {
    /// `report` shrunk until it encodes under its schema's body cap (``HangReport/WireSchema/maxBodyBytes``).
    /// The black box goes first (its oldest events), then the input latency, which is context too (the
    /// least frequent rows, then the scroll jank histograms, then the whole block); then the field data that a
    /// later report carries when it is cut (the earlier launches' sections, then the histograms with the fewest
    /// samples), so hangs keep the room they had without them; then what is gone once cut: the shortest hangs
    /// (the blocking samples, first in the list, after every timed one), CPU exceptions and intervals:
    /// MetricKit's last ones before the main-turn and input-queueing histograms, which the builder also keeps
    /// at the interval cap (``HangReportBuilder/addMainThread(_:to:)``). The stability counts stay.
    static func fitted(_ report: HangReport) -> HangReport {
        var report = report
        let limit = bodyLimit(of: report)
        while encodedSize(report) > limit {
            if trimBlackBox(&report, limit: limit) || trimInputLatency(&report) || trimFieldData(&report) { continue }
            if !report.hangs.isEmpty { report.hangs.removeLast() } else if !report.cpuExceptions.isEmpty {
                report.cpuExceptions.removeLast()
            } else if !trimInterval(&report) { break }
        }
        return report
    }

    /// The body cap of `report`'s schema.
    static func bodyLimit(of report: HangReport) -> Int {
        HangReport.WireSchema(rawValue: report.schema)?.maxBodyBytes ?? HangReport.maxBodyBytes
    }

    private static func encodedSize(_ report: HangReport) -> Int {
        (try? HangReport.encoder.encode(report).count) ?? 0
    }

    /// Keeps the newest black-box events that fit `limit` (a binary search: a few encodes, not one per
    /// event); none when even one does not. False when there is no black box.
    static func trimBlackBox(_ report: inout HangReport, limit: Int) -> Bool {
        guard let events = report.blackbox, !events.isEmpty else { return false }
        var fits = 0
        var over = events.count
        while over - fits > 1 {
            let middle = (fits + over) / 2
            report.blackbox = Array(events.suffix(middle))
            if encodedSize(report) <= limit { fits = middle } else { over = middle }
        }
        report.blackbox = fits == 0 ? nil : Array(events.suffix(fits))
        return true
    }

    /// Removes the last earlier launch's section, else the histogram with the fewest samples; false when
    /// neither is left.
    static func trimFieldData(_ report: inout HangReport) -> Bool {
        if var sections = report.launchSections, !sections.isEmpty {
            sections.removeLast()
            report.launchSections = sections.isEmpty ? nil : sections
        } else if var histograms = report.histograms,
                  let fewest = histograms.indices.min(by: { histograms[$0].count < histograms[$1].count }) {
            histograms.remove(at: fewest)
            report.histograms = histograms.isEmpty ? nil : histograms
        } else {
            return false
        }
        return true
    }

    /// Removes the last MetricKit interval, else the last main-thread one; false when none is left.
    static func trimInterval(_ report: inout HangReport) -> Bool {
        if let index = report.intervals.lastIndex(where: { $0.category != HangReport.mainThreadCategory }) {
            report.intervals.remove(at: index)
        } else if !report.intervals.isEmpty {
            report.intervals.removeLast()
        } else {
            return false
        }
        return true
    }

    /// Removes one piece of `report`'s input latency; false when it has none left.
    static func trimInputLatency(_ report: inout HangReport) -> Bool {
        if report.inputLatency?.isEmpty == false {
            report.inputLatency?.removeLast()
        } else if report.scrollJank?.histograms.isEmpty == false {
            _ = report.scrollJank?.histograms.popLast()
        } else if report.inputLatencyBucketEdgesMs != nil || report.inputLatency != nil || report.scrollJank != nil {
            report.inputLatencyBucketEdgesMs = nil
            report.inputLatency = nil
            report.scrollJank = nil
        } else {
            return false
        }
        return true
    }
}
