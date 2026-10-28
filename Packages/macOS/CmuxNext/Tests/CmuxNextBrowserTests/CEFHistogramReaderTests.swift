@testable import CmuxNextBrowser
import CmuxNextInputCore
import Foundation
import Testing

/// Chromium's EventLatency and ScrollJank histograms through `Browser.getHistograms`: canned
/// replies fold into ledger rows with source `chromium`, keep Chromium's count and sum, map Chromium's
/// buckets onto cmux's edges and leave unknown histograms out; the reader asks only when read or reset.
@MainActor @Suite struct CEFHistogramReaderTests {
    /// A Chromium that answers `Browser.getHistograms` from canned histograms and records each query.
    @MainActor final class FakeChromium {
        var histograms: [String: String] = [:]
        var queries: [String] = []
        var failure: CEFHistogramReadError?

        func set(_ name: String, sum: Int64, buckets: [(low: Int64, high: Int64, count: Int64)]) {
            let count = buckets.reduce(0) { $0 + $1.count }
            let bucketsJSON = buckets.map { #"{"low":\#($0.low),"high":\#($0.high),"count":\#($0.count)}"# }.joined(separator: ",")
            histograms[name] = #"{"name":"\#(name)","sum":\#(sum),"count":\#(count),"buckets":[\#(bucketsJSON)]}"#
        }

        func answer(_ query: String) -> Result<String, CEFHistogramReadError> {
            queries.append(query)
            if let failure { return .failure(failure) }
            let matching = histograms.filter { $0.key.contains(query) }.sorted { $0.key < $1.key }.map(\.value)
            return .success(#"{"histograms":[\#(matching.joined(separator: ","))]}"#)
        }

        var reader: CEFHistogramReader {
            CEFHistogramReader { [self] query in answer(query) }
        }
    }

    static let overflowHigh = Int64(Int32.max)

    @Test func cannedReplyKeepsCountAndSumAndMapsEdges() async {
        let chromium = FakeChromium()
        // 7.0-8.0 ms falls in (6, 8.3]; 8.0-9.0 ms counts at 8.999 ms, in (8.3, 10]; the overflow bucket at 5 s.
        chromium.set("EventLatency.KeyPressed.TotalLatency", sum: 5_030_000,
                     buckets: [(7_000, 8_000, 3), (8_000, 9_000, 2), (5_000_000, Self.overflowHigh, 1)])
        let report = await chromium.reader.read()

        #expect(report.unavailable == nil)
        #expect(report.rendererEventLatency)
        let histogram = report.histograms.first { $0.name == "EventLatency.KeyPressed.TotalLatency" }
        #expect(histogram?.count == 6)
        #expect(histogram?.sum == 5_030_000)
        #expect(histogram?.unit == .microseconds)

        #expect(report.rows.count == 1)
        let row = report.rows.first
        #expect(row?.kind == "keyPress")
        #expect(row?.presentationSource == "chromium")
        #expect(row?.count == 6)
        var expected = [UInt64](repeating: 0, count: InputLatencyBuckets.bucketCount)
        expected[4] = 3
        expected[5] = 2
        expected[InputLatencyBuckets.bucketCount - 1] = 1
        #expect(row?.total.buckets == expected)
        #expect(row?.total.maxMilliseconds == 5_000)
        #expect(row?.total.p50Milliseconds == 8.3)
    }

    @Test func stagesJoinTheirKindsRowAndDevicesMerge() async {
        let chromium = FakeChromium()
        chromium.set("EventLatency.GestureScrollUpdate.Wheel.TotalLatency2", sum: 40_000, buckets: [(9_500, 10_000, 4)])
        chromium.set("EventLatency.GestureScrollUpdate.Touchscreen.TotalLatency2", sum: 10_000, buckets: [(9_500, 10_000, 1)])
        // The old total of the same base name: the newest version counts, so no sample counts twice.
        chromium.set("EventLatency.GestureScrollUpdate.Wheel.TotalLatency", sum: 40_000, buckets: [(9_500, 10_000, 4)])
        chromium.set("EventLatency.GestureScrollUpdate.Wheel.GenerationToRendererCompositor", sum: 2_000, buckets: [(400, 500, 4)])
        let report = await chromium.reader.read()

        #expect(report.rows.count == 1)
        let row = report.rows.first
        #expect(row?.kind == "scrollUpdate")
        #expect(row?.count == 5)
        #expect(row?.stages.map(\.stage) == ["GenerationToRendererCompositor"])
        #expect(row?.stages.first?.histogram.count == 4)
    }

    @Test func rowStagesAreTopLevelInPipelineOrder() async {
        let chromium = FakeChromium()
        chromium.set("EventLatency.KeyPressed.TotalLatency", sum: 9_000, buckets: [(8_000, 9_000, 1)])
        // Alphabetical order puts BeginImplFrame... first; the pipeline puts Generation... first.
        chromium.set("EventLatency.KeyPressed.BeginImplFrameToSendBeginMainFrame", sum: 1_000, buckets: [(1_000, 1_100, 1)])
        chromium.set("EventLatency.KeyPressed.GenerationToRendererCompositor", sum: 500, buckets: [(500, 600, 1)])
        chromium.set("EventLatency.KeyPressed.SubmitCompositorFrameToPresentationCompositorFrame", sum: 4_000, buckets: [(4_000, 4_100, 1)])
        // A second whole-pipeline total, a sub-stage of a listed stage and a stage cmux does not know: never stages.
        chromium.set("EventLatency.KeyPressed.TotalLatencyToSwapBegin", sum: 7_000, buckets: [(7_000, 7_100, 1)])
        chromium.set("EventLatency.KeyPressed.SubmitCompositorFrameToPresentationCompositorFrame.StartDrawToSwapStart",
                     sum: 2_000, buckets: [(2_000, 2_100, 1)])
        chromium.set("EventLatency.KeyPressed.SomethingNewToSomethingElse", sum: 100, buckets: [(100, 110, 1)])
        let report = await chromium.reader.read()

        #expect(report.rows.first?.stages.map(\.stage) == ["GenerationToRendererCompositor", "BeginImplFrameToSendBeginMainFrame",
                                                            "SubmitCompositorFrameToPresentationCompositorFrame"])
        // Each is still listed with Chromium's own count and sum.
        let names = Set(report.histograms.map(\.name))
        #expect(names.contains("EventLatency.KeyPressed.TotalLatencyToSwapBegin"))
        #expect(names.contains("EventLatency.KeyPressed.SubmitCompositorFrameToPresentationCompositorFrame.StartDrawToSwapStart"))
        #expect(names.contains("EventLatency.KeyPressed.SomethingNewToSomethingElse"))
    }

    @Test func rowsSayTheyCombineEveryChromiumPage() async {
        let chromium = FakeChromium()
        chromium.set("EventLatency.KeyPressed.TotalLatency", sum: 9_000, buckets: [(8_000, 9_000, 1)])
        chromium.set("EventLatency.MousePressed.TotalLatency", sum: 9_000, buckets: [(8_000, 9_000, 1)])
        let report = await chromium.reader.read()

        // Browser.getHistograms is per process: browser pages and agent pane pages together, so no row
        // takes the name of one surface's slots.
        #expect(report.rows.count == 2)
        #expect(report.rows.allSatisfy { $0.target == "chromiumProcess" })
        let slotTargets = Set(InputTarget.allCases.map { String(describing: $0) })
        #expect(report.rows.allSatisfy { !slotTargets.contains($0.target) })
    }

    @Test func unknownHistogramsAreLeftOut() async {
        let chromium = FakeChromium()
        chromium.set("EventLatency.KeyPressed.TotalLatency", sum: 9_000, buckets: [(8_000, 9_000, 1)])
        // A type cmux has no kind for, a scroll name without its device, and the all-events total.
        chromium.set("EventLatency.TouchPressed.TotalLatency", sum: 9_000, buckets: [(8_000, 9_000, 1)])
        chromium.set("EventLatency.GestureScrollUpdate.TotalLatency2", sum: 9_000, buckets: [(8_000, 9_000, 1)])
        chromium.set("EventLatency.TotalLatency", sum: 9_000, buckets: [(8_000, 9_000, 1)])
        chromium.set("Event.ScrollJank.SomethingNew", sum: 3, buckets: [(3, 4, 1)])
        let report = await chromium.reader.read()

        #expect(report.histograms.map(\.name) == ["EventLatency.KeyPressed.TotalLatency"])
        #expect(report.rows.map(\.kind) == ["keyPress"])
        #expect(report.scrollJank.isEmpty)
    }

    @Test func scrollJankAndSwapBeginHistograms() async {
        let chromium = FakeChromium()
        chromium.set("Event.ScrollJank.DelayedFramesPercentage.FixedWindow", sum: 12, buckets: [(0, 1, 4), (12, 13, 1)])
        chromium.set("Event.Latency.ScrollUpdate.Wheel.TimeToScrollUpdateSwapBegin4", sum: 7_500, buckets: [(7_000, 8_000, 1)])
        let report = await chromium.reader.read()

        #expect(report.scrollJank["Event.ScrollJank.DelayedFramesPercentage.FixedWindow"]?.samples
            == [ScrollJankHistogramSnapshot.Sample(value: 0, count: 4), ScrollJankHistogramSnapshot.Sample(value: 12, count: 1)])
        let jank = report.histograms.first { $0.name.hasPrefix("Event.ScrollJank.") }
        #expect(jank?.unit == .sample)
        #expect(jank?.latency == nil)
        // Ends at swap begin, not at presentation: listed with cmux's edges, never a row.
        let swap = report.histograms.first { $0.name.hasPrefix("Event.Latency.ScrollUpdate.") }
        #expect(swap?.latency?.count == 1)
        #expect(report.rows.isEmpty)
        #expect(!report.rendererEventLatency)
    }

    @Test func asksOnlyWhenReadOrReset() async {
        let chromium = FakeChromium()
        let reader = chromium.reader
        #expect(chromium.queries.isEmpty)
        _ = await reader.read()
        #expect(chromium.queries == CEFHistogramReader.queries)
        await reader.reset()
        #expect(chromium.queries.count == 2 * CEFHistogramReader.queries.count)
    }

    @Test func resetSubtractsTheBaseline() async {
        let chromium = FakeChromium()
        let reader = chromium.reader
        chromium.set("EventLatency.KeyPressed.TotalLatency", sum: 21_000, buckets: [(7_000, 8_000, 3)])
        await reader.reset()
        chromium.set("EventLatency.KeyPressed.TotalLatency", sum: 37_000, buckets: [(7_000, 8_000, 4), (8_000, 9_000, 1)])
        let report = await reader.read()

        let histogram = report.histograms.first
        #expect(histogram?.count == 2)
        #expect(histogram?.sum == 16_000)
        #expect(report.rows.first?.count == 2)
        #expect(report.rows.first?.total.buckets[4] == 1)
        #expect(report.rows.first?.total.buckets[5] == 1)
    }

    @Test func aHistogramThatStartedOverCountsWhole() async {
        let chromium = FakeChromium()
        let reader = chromium.reader
        chromium.set("EventLatency.KeyPressed.TotalLatency", sum: 40_000, buckets: [(7_000, 8_000, 5)])
        await reader.reset()
        // A new Chromium host process: fewer samples than the baseline.
        chromium.set("EventLatency.KeyPressed.TotalLatency", sum: 8_000, buckets: [(7_000, 8_000, 1)])
        #expect(await reader.read().rows.first?.count == 1)
    }

    @Test func aRestartedHistogramAboveItsBaselineCountsWhole() async {
        let chromium = FakeChromium()
        let reader = chromium.reader
        chromium.set("EventLatency.KeyPressed.TotalLatency", sum: 40_000, buckets: [(7_000, 8_000, 5)])
        await reader.reset()
        // A new host with more samples than the baseline, none in the baseline's bucket: it started over.
        chromium.set("EventLatency.KeyPressed.TotalLatency", sum: 126_000, buckets: [(20_000, 22_000, 6)])
        let report = await reader.read()

        let histogram = report.histograms.first
        #expect(histogram?.count == 6)
        #expect(histogram?.sum == 126_000)
        #expect(report.rows.first?.count == 6)
    }

    @Test func aSumBelowItsBaselineStartedOver() {
        // 7.999 ms and 89.999 ms, then a new host's 7 ms, 7 ms and 80 ms: no bucket count went down, the sum did.
        let base = CEFChromiumHistogram(name: "EventLatency.KeyPressed.TotalLatency", sum: 97_998, count: 2,
                                        buckets: [.init(low: 7_000, high: 8_000, count: 1), .init(low: 80_000, high: 90_000, count: 1)])
        let now = CEFChromiumHistogram(name: base.name, sum: 94_000, count: 3,
                                       buckets: [.init(low: 7_000, high: 8_000, count: 2), .init(low: 80_000, high: 90_000, count: 1)])
        #expect(now.subtracting(base) == now)
    }

    @Test func aFailedResetCountsNothingFromBeforeIt() async {
        let chromium = FakeChromium()
        let reader = chromium.reader
        // Samples from an earlier phase; then every page closed, Chromium still running.
        chromium.set("EventLatency.KeyPressed.TotalLatency", sum: 40_000, buckets: [(7_000, 8_000, 5)])
        chromium.failure = .noBrowser
        await reader.reset()
        // A page opens and gets input: Chromium answers again.
        chromium.failure = nil
        chromium.set("EventLatency.KeyPressed.TotalLatency", sum: 49_000, buckets: [(7_000, 8_000, 5), (8_000, 9_000, 1)])
        let stale = await reader.read()
        #expect(stale.unavailable == "reset_no_browser")
        #expect(stale.rows.isEmpty)
        #expect(stale.histograms.isEmpty)

        // A reset that reads Chromium starts the window over.
        await reader.reset()
        chromium.set("EventLatency.KeyPressed.TotalLatency", sum: 58_000, buckets: [(7_000, 8_000, 5), (8_000, 9_000, 2)])
        let report = await reader.read()
        #expect(report.unavailable == nil)
        #expect(report.rows.first?.count == 1)
    }

    @Test func aResetBeforeChromiumStartsCountsEverySample() async {
        let chromium = FakeChromium()
        let reader = chromium.reader
        chromium.failure = .notStarted
        await reader.reset()
        #expect(await reader.read().unavailable == "not_started")
        // Chromium starts after the reset: all it records came after it.
        chromium.failure = nil
        chromium.set("EventLatency.KeyPressed.TotalLatency", sum: 9_000, buckets: [(8_000, 9_000, 1)])
        let report = await reader.read()
        #expect(report.unavailable == nil)
        #expect(report.rows.first?.count == 1)
    }

    @Test func failuresSayWhy() async {
        let chromium = FakeChromium()
        chromium.failure = .noBrowser
        let report = await chromium.reader.read()
        #expect(report.unavailable == "no_browser")
        #expect(report.rows.isEmpty)
        #expect(chromium.queries.count == 1)

        let malformed = CEFHistogramReader { _ in .success("[]") }
        #expect(await malformed.read().unavailable == "malformed_reply")
    }

    @Test func reportEncodesSnakeCaseKeys() async throws {
        let chromium = FakeChromium()
        chromium.set("EventLatency.KeyPressed.TotalLatency", sum: 9_000, buckets: [(8_000, 9_000, 1)])
        let data = try JSONEncoder().encode(await chromium.reader.read())
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["rows", "scroll_jank", "histograms", "renderer_event_latency"])
        let row = try #require((object["rows"] as? [[String: Any]])?.first)
        #expect(row["presentation_source"] as? String == "chromium")
    }

    @Test func eventLatencyNames() throws {
        let key = CEFEventLatencyName("EventLatency.KeyPressed.SubmitCompositorFrameToPresentationCompositorFrame.StartDrawToSwapStart")
        #expect(key?.kind == .keyPress)
        #expect(key?.base == "EventLatency.KeyPressed")
        #expect(key?.totalVersion == nil)
        // A sub-stage: listed, never a row stage.
        #expect(key?.stageOrder == nil)
        #expect(CEFEventLatencyName("EventLatency.GesturePinchUpdate.Touchpad.TotalLatency")?.totalVersion == 0)
        #expect(CEFEventLatencyName("EventLatency.GestureScrollUpdate.Wheel.TotalLatency2")?.totalVersion == 2)
        #expect(CEFEventLatencyName("EventLatency.GestureScrollUpdate.Wheel.TotalLatency2")?.stageOrder == nil)
        let toSwapBegin = CEFEventLatencyName("EventLatency.KeyPressed.TotalLatencyToSwapBegin")
        #expect(toSwapBegin?.totalVersion == nil)
        #expect(toSwapBegin?.stageOrder == nil)
        let generation = try #require(CEFEventLatencyName("EventLatency.KeyPressed.GenerationToRendererCompositor")?.stageOrder)
        let presentation = try #require(CEFEventLatencyName("EventLatency.KeyPressed.SubmitCompositorFrameToPresentationCompositorFrame")?.stageOrder)
        #expect(generation < presentation)
        #expect(CEFEventLatencyName("EventLatency.KeyPressed.") == nil)
        #expect(CEFEventLatencyName("Graphics.Smoothness.EventLatency.KeyPressed.TotalLatency") == nil)
    }
}
