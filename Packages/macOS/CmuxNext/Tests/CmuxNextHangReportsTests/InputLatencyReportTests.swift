import CmuxNextInputCore
@testable import CmuxNextHangReports
import Foundation
import Testing

/// Input latency in the opt-in report (p04-input-010): `input_latency[]` rows whose bucket counts
/// add up to `count`, Chrome's scroll jank histograms under their names, the display's refresh
/// rate and VRR label, numbers and enum case names only, and nothing when no input was counted.
/// Run: `swift test --filter InputLatencyReportTests`.
struct InputLatencyReportTests {
    private static let ms: UInt64 = 1_000_000
    private static let vsync: UInt64 = 16_666_667

    private static func slot(_ kind: InputEventKind, target: InputTarget = .terminal, entrypoint: InputEntrypoint = .person,
                             source: InputPresentationSource = .estimatedVsync, updated: Bool = true,
                             generatedMs: UInt64, presentedMs: UInt64) -> InputLatencySlot {
        var slot = InputLatencySlot(kind: kind, target: target, entrypoint: entrypoint, presentationSource: source,
                                    causedFrameUpdate: updated)
        slot.generated = generatedMs * ms
        slot.presented = presentedMs * ms
        return slot
    }

    /// 300 keys and clicks of known latencies, then one scroll with a janky frame and the start of
    /// the next scroll, so Chrome's PerScroll histograms are emitted.
    static func fieldSnapshot() -> InputLatencySnapshot {
        var slots: [InputLatencySlot] = []
        for index in 0..<300 {
            let generated = 1_000 + UInt64(index) * 2
            let latency = UInt64(index % 40) + 1
            let kind: InputEventKind = index.isMultiple(of: 3) ? .keyPress : .mousePress
            let target: InputTarget = index.isMultiple(of: 2) ? .terminal : .sidebar
            slots.append(slot(kind, target: target, generatedMs: generated, presentedMs: generated + latency))
        }
        slots.append(slot(.scrollFirstUpdate, target: .layout, generatedMs: 10_000, presentedMs: 10_010))
        slots.append(slot(.scrollUpdate, target: .layout, generatedMs: 10_012, presentedMs: 10_027))
        // 50 ms after the previous frame with its input already there: janky, 2 vsyncs missed.
        slots.append(slot(.scrollUpdate, target: .layout, generatedMs: 10_020, presentedMs: 10_077))
        slots.append(slot(.scrollUpdate, target: .layout, generatedMs: 10_080, presentedMs: 10_094))
        var begin = InputLatencySlot(kind: .scrollBegin, target: .layout, entrypoint: .person)
        begin.generated = 11_000 * ms
        slots.append(begin)
        var ledger = InputLatencyLedger()
        ledger.fold(InputLatencyBatch(slots: slots, vsyncNanos: vsync))
        return ledger.snapshot
    }

    static func fieldInput(display: HangReport.Display = HangReport.Display(refreshHz: 120, vrr: true))
        -> HangReportBuilder.InputLatencyInput {
        HangReportBuilder.InputLatencyInput(snapshot: fieldSnapshot(), display: display)
    }

    private static func report(_ input: HangReportBuilder.InputLatencyInput?) -> HangReport {
        HangReportFixtures.builder().build(context: HangReportFixtures.context(), watchdog: StallAggregate(), metricKit: [],
                                           inputLatency: input)
    }

    @Test func eachRowsBucketsAddUpToItsCount() throws {
        let report = Self.report(Self.fieldInput())
        let rows = try #require(report.inputLatency)
        #expect(!rows.isEmpty)
        for row in rows {
            #expect(row.buckets.count == InputLatencyBuckets.bucketCount)
            #expect(row.buckets.reduce(0, +) == row.count)
        }
        // The 300 keys and clicks plus the three scroll frames that reached a presented time.
        #expect(rows.reduce(0) { $0 + $1.count } == 300 + 4)
        #expect(rows.map(\.count) == rows.map(\.count).sorted(by: >), "the most frequent row first")
        let keys = try #require(rows.first { $0.kind == "keyPress" && $0.target == "terminal" })
        #expect(keys.entrypoint == "person")
        #expect(keys.presentationSource == "estimatedVsync")
        #expect(keys.maxMs <= 40)
        #expect(report.inputLatencyBucketEdgesMs == [1, 2, 4, 6, 8.3, 10, 12, 16.7, 24, 33, 50, 100, 250])
    }

    @Test func scrollJankUsesChromesNamesAndCounts() throws {
        let jank = try #require(Self.report(Self.fieldInput()).scrollJank)
        #expect(jank.presentedFrames == 3)
        #expect(jank.delayedFrames == 1)
        #expect(jank.skippedFrames == 1, "a scroll's first frame has no frame before it")
        let names = jank.histograms.map(\.name)
        #expect(names == [
            "Event.ScrollJank.DelayedFramesPercentage.PerScroll",
            "Event.ScrollJank.MissedVsyncsSum.PerScroll",
            "Event.ScrollJank.MissedVsyncsMax.PerScroll",
        ])
        #expect(jank.histograms[0].samples == [.init(value: 33, count: 1)])
        #expect(jank.histograms[1].samples == [.init(value: 2, count: 1)])
    }

    @Test func theDisplayIsLabelledAndAnOutOfRangeRateIsUnknown() {
        #expect(Self.report(Self.fieldInput()).display == HangReport.Display(refreshHz: 120, vrr: true))
        let odd = Self.report(Self.fieldInput(display: HangReport.Display(refreshHz: 50_000, vrr: false)))
        #expect(odd.display == HangReport.Display(refreshHz: 0, vrr: false))
    }

    @Test func theWireNamesAreSnakeCaseAndTheScanPasses() throws {
        let body = try HangReport.encoder.encode(Self.report(Self.fieldInput()))
        let text = String(decoding: body, as: UTF8.self)
        for key in ["\"input_latency_bucket_edges_ms\"", "\"input_latency\"", "\"presentation_source\"", "\"max_ms\"",
                    "\"scroll_jank\"", "\"presented_frames\"", "\"delayed_frames\"", "\"skipped_frames\"",
                    "\"display\"", "\"refresh_hz\"", "\"vrr\""] {
            #expect(text.contains(key), "missing \(key)")
        }
        #expect(PrivacyLeakScanner(forbiddenTerms: HangReportFixtures.forbiddenTerms).findings(in: body).isEmpty)
        let decoded = try JSONDecoder().decode(HangReport.self, from: body)
        #expect(decoded == Self.report(Self.fieldInput()), "the report round-trips")
    }

    @Test func noInputMeansNoInputKeysAndTheGoldenBytesStay() throws {
        for input in [nil, HangReportBuilder.InputLatencyInput(snapshot: InputLatencyLedger().snapshot,
                                                               display: HangReport.Display(refreshHz: 60, vrr: false))] {
            let report = Self.report(input)
            #expect(report.inputLatency == nil)
            #expect(report.scrollJank == nil)
            #expect(report.display == nil)
            #expect(report.inputLatencyBucketEdgesMs == nil)
            let body = try HangReport.encoder.encode(report)
            let text = String(decoding: body, as: UTF8.self)
            #expect(!text.contains("input_latency") && !text.contains("scroll_jank") && !text.contains("display"))
        }
        let golden = try JSONDecoder().decode(HangReport.self, from: Data(HangReportWireFormatTests.golden.utf8))
        let goldenBody = try HangReport.encoder.encode(golden)
        #expect(String(decoding: goldenBody, as: UTF8.self) == HangReportWireFormatTests.golden)
    }

    @Test func aRowWithAnUnknownLabelOrBucketShapeIsLeftOut() {
        let histogram = InputLatencyHistogramSnapshot(count: 1, buckets: [UInt64](repeating: 0, count: InputLatencyBuckets.bucketCount - 1) + [1],
                                                      p50Milliseconds: nil, p95Milliseconds: nil, p99Milliseconds: nil,
                                                      maxMilliseconds: 300)
        let short = InputLatencyHistogramSnapshot(count: 1, buckets: [1], p50Milliseconds: nil, p95Milliseconds: nil,
                                                  p99Milliseconds: nil, maxMilliseconds: 1)
        let rows = [
            InputLatencySnapshot.Row(kind: "/Users/alice", target: "terminal", entrypoint: "person",
                                     presentationSource: "estimatedVsync", count: 1, total: histogram, stages: []),
            InputLatencySnapshot.Row(kind: "keyPress", target: "terminal", entrypoint: "person",
                                     presentationSource: "estimatedVsync", count: 1, total: short, stages: []),
            InputLatencySnapshot.Row(kind: "keyPress", target: "terminal", entrypoint: "person",
                                     presentationSource: "metalPresented", count: 7, total: histogram, stages: []),
        ]
        let kept = HangReportBuilder.inputLatencyRows(rows)
        #expect(kept.map(\.presentationSource) == ["metalPresented"])
        #expect(kept.first?.count == 1, "count is the sum of the buckets, not the row's own count")
        #expect(kept.first?.maxMs == 300)
    }

    @Test func scrollJankValuesAreClampedToChromesRanges() {
        let jank = InputLatencySnapshot.ScrollJank(
            presentedFrames: 2, delayedFrames: 5, skippedFrames: 0,
            histograms: [
                ScrollJankHistograms.Name.delayedFramesPercentageFixedWindow.rawValue:
                    ScrollJankHistogramSnapshot(samples: [.init(value: 250, count: 1), .init(value: -3, count: 2)]),
                ScrollJankHistograms.Name.missedVsyncsMaxFixedWindow.rawValue:
                    ScrollJankHistogramSnapshot(samples: [.init(value: 900, count: 1)]),
                "alice@example.com": ScrollJankHistogramSnapshot(samples: [.init(value: 1, count: 1)]),
            ])
        let safe = HangReportBuilder.scrollJank(jank)
        #expect(safe.delayedFrames == 2)
        #expect(safe.histograms.map(\.name) == [
            "Event.ScrollJank.DelayedFramesPercentage.FixedWindow", "Event.ScrollJank.MissedVsyncsMax.FixedWindow",
        ])
        #expect(safe.histograms[0].samples == [.init(value: 0, count: 2), .init(value: 100, count: 1)])
        #expect(safe.histograms[1].samples == [.init(value: HangReport.maxMissedVsyncs, count: 1)])
    }

    @Test func aReportWithOnlyInputLatencyHasFindings() {
        var report = Self.report(nil)
        #expect(report.hasNoFindings)
        report = Self.report(Self.fieldInput())
        #expect(!report.hasNoFindings)
    }
}
