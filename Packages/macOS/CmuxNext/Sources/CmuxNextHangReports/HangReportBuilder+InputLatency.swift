import CmuxNextInputCore

/// The input latency part of a report, copied by allow-list like the rest: labels
/// only from the input enums' closed sets, bucket edges from ``InputLatencyBuckets``, counts and
/// milliseconds clamped. A row whose labels or bucket shape do not match is left out.
extension HangReportBuilder {
    /// The highest refresh rate a report names; a larger value is sent as 0 (unknown).
    static let maxRefreshHz = 1_000

    static let inputKinds = Set(InputEventKind.allCases.map { String(describing: $0) })
    static let inputTargets = Set(InputTarget.allCases.map { String(describing: $0) })
    static let inputEntrypoints = Set(InputEntrypoint.allCases.map { String(describing: $0) })
    static let presentationSources = Set(InputPresentationSource.allCases.map { String(describing: $0) })
    static let scrollJankNames = Set(ScrollJankHistograms.Name.allCases.map(\.rawValue))

    /// Sets the report's three input fields from `snapshot`, or leaves them absent when it
    /// counted nothing, and its interactions when there was one.
    static func addInputLatency(_ snapshot: InputLatencySnapshot, to report: inout HangReport) {
        report.interactionLatency = interactionLatency(snapshot.interactions)
        let rows = inputLatencyRows(snapshot.rows)
        let jank = scrollJank(snapshot.scrollJank)
        guard !rows.isEmpty || !jank.isEmpty else { return }
        report.inputLatencyBucketEdgesMs = InputLatencyBuckets.edgesNanos.map { roundedMilliseconds(Double($0) / 1_000_000) }
        report.inputLatency = rows
        report.scrollJank = jank
    }

    /// The rows with known labels and the ledger's bucket shape, merged by key, the most
    /// frequent first, capped. `count` is the sum of the buckets, so the two always agree.
    static func inputLatencyRows(_ rows: [InputLatencySnapshot.Row]) -> [HangReport.InputLatencyRow] {
        var merged: [RowKey: HangReport.InputLatencyRow] = [:]
        for row in rows {
            guard inputKinds.contains(row.kind), inputTargets.contains(row.target),
                  inputEntrypoints.contains(row.entrypoint), presentationSources.contains(row.presentationSource),
                  row.total.buckets.count == InputLatencyBuckets.bucketCount else { continue }
            let display = safeDisplay(row.display)
            let key = RowKey(kind: row.kind, target: row.target, entrypoint: row.entrypoint,
                             presentationSource: row.presentationSource, display: display)
            let maxMs = safeMilliseconds(row.total.maxMilliseconds)
            if var existing = merged[key] {
                existing.buckets = zip(existing.buckets, row.total.buckets).map { $0 &+ $1 }
                existing.maxMs = max(existing.maxMs, maxMs)
                merged[key] = existing
            } else {
                merged[key] = HangReport.InputLatencyRow(kind: row.kind, target: row.target, entrypoint: row.entrypoint,
                                                         presentationSource: row.presentationSource, display: display,
                                                         count: 0, buckets: row.total.buckets, maxMs: maxMs)
            }
        }
        let counted = merged.values.compactMap { row -> HangReport.InputLatencyRow? in
            var row = row
            row.count = row.buckets.reduce(0, &+)
            return row.count > 0 ? row : nil
        }
        let sorted = counted.sorted { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return (lhs.kind, lhs.target, lhs.entrypoint, lhs.presentationSource, lhs.display.refreshHz, lhs.display.vrr ? 1 : 0)
                < (rhs.kind, rhs.target, rhs.entrypoint, rhs.presentationSource, rhs.display.refreshHz, rhs.display.vrr ? 1 : 0)
        }
        return Array(sorted.prefix(HangReport.maxInputLatencyRows))
    }

    /// `interactions` with a positive count, a known kind and milliseconds in 0 ms...one day with two
    /// decimals (the percentile at most the worst), else nil. The target stays on the Mac.
    static func interactionLatency(_ interactions: InputLatencySnapshot.Interactions) -> HangReport.InteractionLatency? {
        guard interactions.count > 0, let kind = interactions.kindOfWorst, HangReport.InteractionLatency.kinds.contains(kind)
        else { return nil }
        let worst = safeMilliseconds(interactions.worstMilliseconds)
        return HangReport.InteractionLatency(count: interactions.count, worstMs: worst,
                                             highPctMs: min(safeMilliseconds(interactions.highPercentileMilliseconds), worst),
                                             kindOfWorst: kind)
    }

    /// The display label as sent: a refresh rate above ``maxRefreshHz`` or below 0 is unknown (0).
    static func safeDisplay(_ display: InputDisplayClass) -> HangReport.Display {
        HangReport.Display(refreshHz: (0...maxRefreshHz).contains(display.refreshHz) ? display.refreshHz : 0, vrr: display.vrr)
    }

    /// Chrome's histograms by their known names only, in Chrome's order; values clamped to
    /// Chrome's ranges (a percentage to 100, missed vsyncs to ``HangReport/maxMissedVsyncs``).
    static func scrollJank(_ jank: InputLatencySnapshot.ScrollJank) -> HangReport.ScrollJank {
        let histograms = ScrollJankHistograms.Name.allCases.compactMap { name -> HangReport.ScrollJank.Histogram? in
            guard let emitted = jank.histograms[name.rawValue] else { return nil }
            let cap = isPercentage(name) ? 100 : HangReport.maxMissedVsyncs
            var counts: [Int: UInt64] = [:]
            for sample in emitted.samples where sample.count > 0 {
                counts[min(max(0, sample.value), cap), default: 0] &+= sample.count
            }
            guard !counts.isEmpty else { return nil }
            return HangReport.ScrollJank.Histogram(
                name: name.rawValue,
                samples: counts.keys.sorted().map { HangReport.ScrollJank.Histogram.Sample(value: $0, count: counts[$0] ?? 0) })
        }
        return HangReport.ScrollJank(presentedFrames: jank.presentedFrames,
                                     delayedFrames: min(jank.delayedFrames, jank.presentedFrames),
                                     skippedFrames: jank.skippedFrames, histograms: histograms)
    }

    static func isPercentage(_ name: ScrollJankHistograms.Name) -> Bool {
        switch name {
        case .delayedFramesPercentageFixedWindow, .delayedFramesPercentagePerScroll: true
        case .missedVsyncsSumFixedWindow, .missedVsyncsMaxFixedWindow, .missedVsyncsSumPerScroll,
             .missedVsyncsMaxPerScroll: false
        }
    }

    /// Milliseconds in 0 ms...one day with two decimals; 0 when nil or not finite.
    static func safeMilliseconds(_ value: Double?) -> Double {
        guard let value, value.isFinite else { return 0 }
        return roundedMilliseconds(min(max(0, value), Double(HistogramBucket.maxMs)))
    }

    static func roundedMilliseconds(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    /// A row's merge key.
    struct RowKey: Hashable {
        let kind: String
        let target: String
        let entrypoint: String
        let presentationSource: String
        let display: HangReport.Display
    }
}
