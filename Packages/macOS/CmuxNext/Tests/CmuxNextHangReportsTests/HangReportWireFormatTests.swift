@testable import CmuxNextHangReports
import Foundation
import Testing

/// Schema 2 on the wire: the same bytes the web route's tests decode
/// (web/tests/fixtures/hang-report-schema2.json), so client and server cannot drift. Schema 3's
/// active seconds and main-thread histograms: ``golden3``, the bytes the PL-telemetry web decode PR
/// copies to web/tests/fixtures/hang-report-schema3-main-thread.json.
struct HangReportWireFormatTests {
    static let golden = #"{"app":{"build":"2123456789012","channel":"nightly","version":"0.70.0"},"counts":{"panes":"6-10","tabs":"31-100","windows":"1","workspaces":"11-30"},"cpuExceptions":[{"cpuMs":90000,"frames":[{"image":"other"},{"image":"libsystem_kernel.dylib","offset":30,"uuid":"BBBBBBBB-CCCC-3DDD-8EEE-FFFFFFFFFFFF"}],"sampledMs":180000}],"day":"2026-10-23","hangs":[{"durationMs":2340,"frames":[{"image":"other"},{"image":"AppKit","offset":123456,"uuid":"8B1E5C0A-1D4F-3B2E-A6C7-9F8E7D6C5B4A"},{"image":"cmux NEXT Nightly","offset":777,"uuid":"3F0C9E43-7A61-3C8E-9C1A-2B7F5D0E9A11"},{"image":"GhosttyKit","offset":55,"uuid":"77A62F2E-8212-30F3-84C1-E8497440ACF8"}],"kind":"hang","source":"metrickit"},{"cpuMs":290,"durationMs":300,"frames":[{"image":"other"},{"image":"AppKit","offset":8192,"uuid":"8B1E5C0A-1D4F-3B2E-A6C7-9F8E7D6C5B4A"}],"kind":"stall","source":"watchdog"}],"hardware":{"arch":"arm64","chip":"Apple M4 Pro","cores":14,"memoryGB":48},"installId":"0b8d4a51-6c9e-4f0f-8f53-3c2d7b4f9e20","intervals":[{"buckets":[{"count":1100,"highMs":10,"lowMs":0},{"count":100,"highMs":20,"lowMs":10}],"category":"motion","count":1200,"hitchMsPerS":0.4,"name":"motion.frame"}],"metrics":{"hangTime":[{"count":40,"highMs":100,"lowMs":0}],"launchExtended":[],"launchFirstDraw":[{"count":2,"highMs":300,"lowMs":200}],"launchOptimizedFirstDraw":[],"launchResume":[],"scrollHitchMsPerS":1.5},"os":{"version":"15.7.4"},"reportId":"5f1c7c1e-2b9b-4a8e-9c62-0f0d2b0b8a11","schema":2,"stallHistogram":[{"count":1,"highMs":500,"lowMs":250}]}"#

    @Test func theGoldenReportRoundTripsToTheSameBytes() throws {
        let report = try JSONDecoder().decode(HangReport.self, from: Data(Self.golden.utf8))
        let encoded = try HangReport.encoder.encode(report)
        #expect(String(decoding: encoded, as: UTF8.self) == Self.golden)
        #expect(PrivacyLeakScanner(forbiddenTerms: HangReportFixtures.forbiddenTerms).findings(in: encoded).isEmpty)
    }

    @Test func theBuilderWritesTheGoldensShape() throws {
        // Every interval category a schema 2 report may carry is a signpost category the server
        // accepts (the golden's); the `main` category is schema 3 only (golden3).
        let report = try JSONDecoder().decode(HangReport.self, from: Data(Self.golden.utf8))
        #expect(report.intervals.allSatisfy { HangReportSignposts.allows(category: $0.category, name: $0.name) })
        #expect(HangReportSignposts.categories == ["action", "motion", "key", "switch", "create", "cef", "launch"])
    }

    // MARK: Active seconds and the main-thread histograms (p12-perf-process-043)

    /// `MainTurnHistogram.edgesNanos` (CmuxNextControl): 50 µs times 1.2 per edge, then 10 s.
    static let turnEdgesNanos: [UInt64] = {
        var edges: [UInt64] = []
        var edge = 50_000.0
        while edge < 10_000_000_000 {
            edges.append(UInt64(edge.rounded()))
            edge *= 1.2
        }
        return edges + [10_000_000_000]
    }()

    /// Counts in the fine bucket of each sample.
    static func counts(_ samplesNanos: [UInt64]) -> [UInt64] {
        var counts = [UInt64](repeating: 0, count: turnEdgesNanos.count + 1)
        for sample in samplesNanos {
            counts[turnEdgesNanos.firstIndex { sample < $0 } ?? turnEdgesNanos.count] += 1
        }
        return counts
    }

    static let turns: [UInt64] = Array(repeating: 200_000, count: 900) + Array(repeating: 3_600_000, count: 60)
        + Array(repeating: 16_000_000, count: 39) + [12_000_000_000]
    static let queueing: [UInt64] = Array(repeating: 1_200_000, count: 40) + [40_000_000]

    static func mainThread(activeSeconds: Int = 5_400) -> HangReportBuilder.MainThreadInput {
        HangReportBuilder.MainThreadInput(activeSeconds: activeSeconds, edgesNanos: turnEdgesNanos,
                                          turnCounts: counts(turns), inputQueueingCounts: counts(queueing))
    }

    static func report(_ schema: HangReport.WireSchema, mainThread: HangReportBuilder.MainThreadInput?) -> HangReport {
        HangReportFixtures.builder(wireSchema: schema).build(context: HangReportFixtures.context(), watchdog: StallAggregate(),
                                                             metricKit: [], mainThread: mainThread)
    }

    @Test func schemaTwoCarriesNoActiveSecondsAndNoMainThreadHistograms() throws {
        let with = Self.report(.v2, mainThread: Self.mainThread())
        #expect(with == Self.report(.v2, mainThread: nil))
        let json = String(decoding: try HangReport.encoder.encode(with), as: UTF8.self)
        #expect(!json.contains("active_seconds"))
        #expect(!json.contains(HangReport.mainThreadCategory + "\""))
    }

    @Test func schemaThreeSendsActiveSecondsAndBothHistogramsAsIntervals() throws {
        let report = Self.report(.v3, mainThread: Self.mainThread())
        #expect(report.activeSeconds == 5_400)
        #expect(report.intervals.map(\.name) == [HangReport.mainTurnInterval, HangReport.inputQueueingInterval])
        #expect(report.intervals.allSatisfy { $0.category == HangReport.mainThreadCategory && $0.hitchMsPerS == nil })
        // The main category is not a signpost category, so no MetricKit interval can claim it.
        #expect(!HangReportSignposts.categories.contains(HangReport.mainThreadCategory))
        #expect(report.intervals.allSatisfy { $0.name.range(of: HangReportSignposts.namePattern, options: .regularExpression) != nil })
        #expect(!report.hasNoFindings)

        let turn = try #require(report.intervals.first)
        #expect(turn.count == Self.turns.count)
        #expect(turn.buckets.reduce(0) { $0 + $1.count } == Self.turns.count)
        #expect(turn.buckets == [
            HistogramBucket(lowMs: 0, highMs: 1, count: 900),
            HistogramBucket(lowMs: 3, highMs: 5, count: 60),
            HistogramBucket(lowMs: 14, highMs: 21, count: 39),
            HistogramBucket(lowMs: 10_000, highMs: HistogramBucket.maxMs, count: 1),
        ])
        let queue = report.intervals[1]
        #expect(queue.buckets == [HistogramBucket(lowMs: 1, highMs: 2, count: 40), HistogramBucket(lowMs: 30, highMs: 43, count: 1)])

        let encoded = try HangReport.encoder.encode(report)
        let json = String(decoding: encoded, as: UTF8.self)
        #expect(json.contains(#""active_seconds":5400"#))
        #expect(json.contains(#""category":"main","count":1000"#))
        #expect(PrivacyLeakScanner(forbiddenTerms: HangReportFixtures.forbiddenTerms).findings(in: encoded).isEmpty)
        #expect(try JSONDecoder().decode(HangReport.self, from: encoded) == report)
    }

    @Test func theTurnHistogramFitsTheWireBucketCapInTheShortestRuns() throws {
        let everyBucket = [UInt64](repeating: 1, count: Self.turnEdgesNanos.count + 1)
        let buckets = try #require(HangReportBuilder.mainThreadBuckets(counts: everyBucket, edgesNanos: Self.turnEdgesNanos))
        #expect(buckets.count == 26)
        #expect(buckets.count <= HistogramBucket.maxBuckets)
        #expect(buckets.reduce(0) { $0 + $1.count } == everyBucket.count)
        #expect(zip(buckets, buckets.dropFirst()).allSatisfy { $0.highMs == $1.lowMs && $0.lowMs < $0.highMs })
        #expect(buckets.first?.lowMs == 0)
        #expect(buckets.last == HistogramBucket(lowMs: 10_000, highMs: HistogramBucket.maxMs, count: 1))
    }

    @Test func aHistogramThatDoesNotMatchItsEdgesIsLeftOut() {
        let edges = Self.turnEdgesNanos
        #expect(HangReportBuilder.mainThreadBuckets(counts: [1, 2], edgesNanos: edges) == nil)
        #expect(HangReportBuilder.mainThreadBuckets(counts: [1, 2, 3], edgesNanos: [5_000_000, 5_000_000]) == nil)
        #expect(HangReportBuilder.mainThreadBuckets(counts: [1], edgesNanos: []) == nil)
        let input = HangReportBuilder.MainThreadInput(activeSeconds: -3, edgesNanos: edges, turnCounts: [1, 2],
                                                      inputQueueingCounts: [UInt64](repeating: 0, count: edges.count + 1))
        let report = Self.report(.v3, mainThread: input)
        #expect(report.intervals.isEmpty)
        #expect(report.activeSeconds == 0)
        #expect(Self.report(.v3, mainThread: Self.mainThread(activeSeconds: .max)).activeSeconds == HangReport.maxActiveSeconds)
    }

    /// Schema 3 with `active_seconds` and both main-thread intervals after a MetricKit one.
    static let golden3 = #"{"active_seconds":5400,"app":{"build":"2123456789012","channel":"nightly","version":"0.70.0"},"counts":{"panes":"6-10","tabs":"31-100","windows":"1","workspaces":"11-30"},"cpuExceptions":[],"day":"2026-10-23","hangs":[],"hardware":{"arch":"arm64","chip":"Apple M4 Pro","cores":14,"memoryGB":48},"installId":"0b8d4a51-6c9e-4f0f-8f53-3c2d7b4f9e20","intervals":[{"buckets":[{"count":1100,"highMs":10,"lowMs":0},{"count":100,"highMs":20,"lowMs":10}],"category":"motion","count":1200,"hitchMsPerS":0.4,"name":"motion.frame"},{"buckets":[{"count":900,"highMs":1,"lowMs":0},{"count":60,"highMs":5,"lowMs":3},{"count":39,"highMs":21,"lowMs":14},{"count":1,"highMs":86400000,"lowMs":10000}],"category":"main","count":1000,"name":"main.turn"},{"buckets":[{"count":40,"highMs":2,"lowMs":1},{"count":1,"highMs":43,"lowMs":30}],"category":"main","count":41,"name":"main.input_queueing"}],"metrics":{"hangTime":[],"launchExtended":[],"launchFirstDraw":[],"launchOptimizedFirstDraw":[],"launchResume":[]},"os":{"version":"15.7.4"},"reportId":"5f1c7c1e-2b9b-4a8e-9c62-0f0d2b0b8a11","schema":3,"stallHistogram":[]}"#

    @Test func theSchemaThreeGoldenRoundTripsAndIsWhatTheBuilderWrites() throws {
        let report = try JSONDecoder().decode(HangReport.self, from: Data(Self.golden3.utf8))
        #expect(String(decoding: try HangReport.encoder.encode(report), as: UTF8.self) == Self.golden3)
        #expect(PrivacyLeakScanner(forbiddenTerms: HangReportFixtures.forbiddenTerms).findings(in: Data(Self.golden3.utf8)).isEmpty)
        let built = HangReportFixtures.builder(wireSchema: .v3).build(
            context: HangReportFixtures.context(), watchdog: StallAggregate(),
            metricKit: [MetricKitInput(signposts: [HangReportFixtures.signposts[0]])], mainThread: Self.mainThread())
        #expect(built.schema == report.schema)
        #expect(built.activeSeconds == report.activeSeconds)
        #expect(built.intervals == report.intervals)
    }

    @Test func theMainThreadHistogramsStayWhenMetricKitFillsTheIntervals() {
        var report = Self.report(.v3, mainThread: nil)
        report.intervals = (0..<HangReport.maxIntervals).map {
            IntervalHistogram(category: "motion", name: "motion.\($0)", count: 1, buckets: [], hitchMsPerS: nil)
        }
        HangReportBuilder.addMainThread(Self.mainThread(), to: &report)
        #expect(report.intervals.count == HangReport.maxIntervals)
        #expect(report.intervals.suffix(2).map(\.name) == [HangReport.mainTurnInterval, HangReport.inputQueueingInterval])
    }

    @Test func aReportWithoutActiveSecondsStillDecodes() throws {
        let schemaTwo = try JSONDecoder().decode(HangReport.self, from: Data(Self.golden.utf8))
        #expect(schemaTwo.activeSeconds == nil)
        var older = schemaTwo
        older.schema = HangReport.WireSchema.v3.rawValue
        let bytes = try HangReport.encoder.encode(older)
        #expect(!String(decoding: bytes, as: UTF8.self).contains("active_seconds"))
        #expect(try JSONDecoder().decode(HangReport.self, from: bytes) == older)
    }

    @Test func aFittedBodyDropsMetricKitIntervalsBeforeTheMainThreadHistograms() throws {
        var report = Self.report(.v3, mainThread: Self.mainThread())
        let metricKit = (0..<(HangReport.maxIntervals - 2)).map { index in
            IntervalHistogram(category: "motion", name: "motion.\(index)", count: 1_000_000,
                              buckets: (0..<HistogramBucket.maxBuckets).map {
                                  HistogramBucket(lowMs: $0 * 1_000, highMs: $0 * 1_000 + 1_000, count: 1_000_000 + $0)
                              }, hitchMsPerS: 0.25)
        }
        report.intervals = metricKit + report.intervals
        #expect(try HangReport.encoder.encode(report).count > HangReport.maxBodyBytes)

        let fitted = HangReportService.fitted(report)
        #expect(try HangReport.encoder.encode(fitted).count <= HangReport.maxBodyBytes)
        #expect(fitted.intervals.suffix(2).map(\.name) == [HangReport.mainTurnInterval, HangReport.inputQueueingInterval])
        #expect(fitted.intervals.dropLast(2).map(\.name) == metricKit.prefix(fitted.intervals.count - 2).map(\.name))
        #expect(fitted.activeSeconds == 5_400)
    }
}
