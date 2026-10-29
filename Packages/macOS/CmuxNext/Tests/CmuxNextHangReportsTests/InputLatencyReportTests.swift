import CmuxNextInputCore
@testable import CmuxNextHangReports
import Foundation
import Testing

/// Input latency in the opt-in report: `input_latency[]` rows whose bucket counts
/// add up to `count`, labelled by display, Chrome's scroll jank histograms under their names,
/// numbers and enum case names only, nothing when no input was counted, and nothing in schema 2;
/// and `interaction_latency`, cmux's INP.
/// Run: `swift test --filter InputLatencyReportTests`.
struct InputLatencyReportTests {
    private static let ms: UInt64 = 1_000_000
    private static let vsync: UInt64 = 16_666_667
    static let proMotion = InputDisplayClass(refreshHz: 120, vrr: true)
    static let external = InputDisplayClass(refreshHz: 60, vrr: false)

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
    /// the next scroll, so Chrome's PerScroll histograms are emitted; all on `display`.
    static func fieldSnapshot(display: InputDisplayClass = proMotion) -> InputLatencySnapshot {
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
        ledger.fold(InputLatencyBatch(slots: slots, vsyncNanos: vsync, display: display))
        return ledger.snapshot
    }

    static func report(_ snapshot: InputLatencySnapshot?, wireSchema: HangReport.WireSchema = .v3) -> HangReport {
        HangReportFixtures.builder(wireSchema: wireSchema).build(
            context: HangReportFixtures.context(), watchdog: StallAggregate(), metricKit: [], inputLatency: snapshot)
    }

    @Test func eachRowsBucketsAddUpToItsCount() throws {
        let report = Self.report(Self.fieldSnapshot())
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
        let jank = try #require(Self.report(Self.fieldSnapshot()).scrollJank)
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

    @Test func rowsOnTwoDisplaysAreSeparateAndLabelled() throws {
        // DC12 "VRR rows labelled": the same keys on a ProMotion panel and a 60 Hz external display.
        var ledger = InputLatencyLedger()
        ledger.fold(InputLatencyBatch(slots: [Self.slot(.keyPress, generatedMs: 1_000, presentedMs: 1_005)],
                                      vsyncNanos: 8_333_333, display: Self.proMotion))
        ledger.fold(InputLatencyBatch(slots: [Self.slot(.keyPress, generatedMs: 2_000, presentedMs: 2_020),
                                              Self.slot(.keyPress, generatedMs: 2_100, presentedMs: 2_120)],
                                      vsyncNanos: Self.vsync, display: Self.external))
        let rows = try #require(Self.report(ledger.snapshot).inputLatency)
        #expect(rows.map(\.display) == [HangReport.Display(refreshHz: 60, vrr: false), HangReport.Display(refreshHz: 120, vrr: true)])
        #expect(rows.map(\.count) == [2, 1])
        let odd = InputDisplayClass(refreshHz: 50_000, vrr: false)
        #expect(HangReportBuilder.safeDisplay(odd) == HangReport.Display(refreshHz: 0, vrr: false), "out of range is unknown")
    }

    @Test func theWireNamesAreSnakeCaseAndTheScanPasses() throws {
        let body = try HangReport.encoder.encode(Self.report(Self.fieldSnapshot()))
        let text = String(decoding: body, as: UTF8.self)
        for key in ["\"input_latency_bucket_edges_ms\"", "\"input_latency\"", "\"presentation_source\"", "\"max_ms\"",
                    "\"scroll_jank\"", "\"presented_frames\"", "\"delayed_frames\"", "\"skipped_frames\"",
                    "\"display\"", "\"refresh_hz\"", "\"vrr\""] {
            #expect(text.contains(key), "missing \(key)")
        }
        #expect(PrivacyLeakScanner(forbiddenTerms: HangReportFixtures.forbiddenTerms).findings(in: body).isEmpty)
        let decoded = try JSONDecoder().decode(HangReport.self, from: body)
        #expect(decoded == Self.report(Self.fieldSnapshot()), "the report round-trips")
    }

    @Test func schemaTwoCarriesNoInputLatency() throws {
        // The schema-2 server refuses unknown keys: a schema-2 build never writes them.
        let report = Self.report(Self.fieldSnapshot(), wireSchema: .v2)
        #expect(report.inputLatency == nil && report.scrollJank == nil && report.inputLatencyBucketEdgesMs == nil)
        let text = String(decoding: try HangReport.encoder.encode(report), as: UTF8.self)
        #expect(!text.contains("input_latency") && !text.contains("scroll_jank"))
    }

    @Test func noInputMeansNoInputKeysAndTheGoldenBytesStay() throws {
        for snapshot in [nil, InputLatencyLedger().snapshot] {
            let report = Self.report(snapshot)
            #expect(report.inputLatency == nil)
            #expect(report.scrollJank == nil)
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

    // MARK: interaction latency (p04-input-097)

    /// 120 key interactions (each a press of key 3 and its release), the press of the last three taking
    /// 300, 200 and 40 ms and the others 4 to 13 ms, through the ledger the report's field source keeps.
    static func interactionSnapshot() -> InputLatencySnapshot {
        var slots: [InputLatencySlot] = []
        for index in 0..<120 {
            let latency: UInt64 = switch index {
            case 117: 300
            case 118: 200
            case 119: 40
            default: 4 + UInt64(index % 10)
            }
            let generated = 1_000 + UInt64(index) * 1_000
            for kind in [InputEventKind.keyPress, .keyRelease] {
                var slot = InputLatencySlot(kind: kind, target: .terminal, entrypoint: .person, keyCode: 3)
                slot.generated = (kind == .keyPress ? generated : generated + 500) * ms
                slot.dispatchEnd = slot.generated + (kind == .keyPress ? latency : 1) * ms
                slots.append(slot)
            }
        }
        var ledger = InputLatencyLedger()
        ledger.fold(InputLatencyBatch(slots: slots, vsyncNanos: vsync, display: proMotion))
        return ledger.snapshot
    }

    @Test func interactionLatencyReportsTheThirdWorstOf120AndPassesTheScanAndTheServerRules() throws {
        let report = Self.report(Self.interactionSnapshot())
        #expect(report.interactionLatency == HangReport.InteractionLatency(count: 120, worstMs: 300, highPctMs: 40, kindOfWorst: "key"))
        #expect(report.inputLatency == nil, "no input reached a presented frame: the interactions stand alone")
        #expect(!report.hasNoFindings)
        let body = try HangReport.encoder.encode(report)
        let text = String(decoding: body, as: UTF8.self)
        #expect(text.contains(#""interaction_latency":{"count":120,"high_pct_ms":40,"kind_of_worst":"key","worst_ms":300}"#))
        #expect(!text.contains("terminal"), "the target of the worst stays on the Mac")
        #expect(PrivacyLeakScanner(forbiddenTerms: HangReportFixtures.forbiddenTerms + ["Key", "tap"]).findings(in: body).isEmpty)
        #expect(HangReportServerRules.violations(in: body).isEmpty)
        #expect(try JSONDecoder().decode(HangReport.self, from: body) == report, "the report round-trips")
    }

    @Test func schemaTwoAndNoInteractionCarryNoInteractionLatency() throws {
        let schema2 = Self.report(Self.interactionSnapshot(), wireSchema: .v2)
        #expect(schema2.interactionLatency == nil)
        #expect(!String(decoding: try HangReport.encoder.encode(schema2), as: UTF8.self).contains("interaction"))
        for snapshot in [nil, InputLatencyLedger().snapshot] {
            let report = Self.report(snapshot)
            #expect(report.interactionLatency == nil)
            #expect(!String(decoding: try HangReport.encoder.encode(report), as: UTF8.self).contains("interaction"))
        }
    }

    @Test func anInteractionOutsideTheClosedSetOrNotAFiniteDurationNeverReachesTheWire() {
        typealias Interactions = InputLatencySnapshot.Interactions
        let kept = HangReportBuilder.interactionLatency(Interactions(count: 3, worstMilliseconds: 12.346,
                                                                     highPercentileMilliseconds: 99, kindOfWorst: "tap"))
        #expect(kept == HangReport.InteractionLatency(count: 3, worstMs: 12.35, highPctMs: 12.35, kindOfWorst: "tap"),
                "two decimals, the percentile at most the worst")
        let huge = HangReportBuilder.interactionLatency(Interactions(count: 1, worstMilliseconds: .infinity,
                                                                     highPercentileMilliseconds: 1e12, kindOfWorst: "drag"))
        #expect(huge == HangReport.InteractionLatency(count: 1, worstMs: 0, highPctMs: 0, kindOfWorst: "drag"))
        for unsafe in [
            Interactions(count: 3, worstMilliseconds: 9, highPercentileMilliseconds: 9, kindOfWorst: "/Users/alice"),
            Interactions(count: 3, worstMilliseconds: 9, highPercentileMilliseconds: 9, kindOfWorst: nil),
            Interactions(count: 0, worstMilliseconds: 9, highPercentileMilliseconds: 9, kindOfWorst: "key"),
        ] {
            #expect(HangReportBuilder.interactionLatency(unsafe) == nil)
        }
    }

    @Test func aReportWithOnlyInputLatencyHasFindings() {
        #expect(Self.report(nil).hasNoFindings)
        #expect(!Self.report(Self.fieldSnapshot()).hasNoFindings)
    }
}
