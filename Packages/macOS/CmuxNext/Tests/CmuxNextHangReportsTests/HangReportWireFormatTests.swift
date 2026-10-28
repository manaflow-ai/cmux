import CmuxNextCompat
import CmuxNextFeatures
@testable import CmuxNextHangReports
import CmuxNextMetrics
import CmuxNextTrace
import Foundation
import Testing

/// Schema 2 on the wire: the same bytes the web route's tests decode
/// (web/tests/fixtures/hang-report-schema2.json), so client and server cannot drift. Schema 3's
/// active seconds and main-thread histograms: ``golden3MainThread``, the bytes the PL-telemetry web decode PR
/// copies to web/tests/fixtures/hang-report-schema3-main-thread.json. The launch's features: ``golden3Features``.
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
        // accepts (the golden's); the `main` category is schema 3 only (golden3MainThread).
        let report = try JSONDecoder().decode(HangReport.self, from: Data(Self.golden.utf8))
        #expect(report.intervals.allSatisfy { HangReportSignposts.allows(category: $0.category, name: $0.name) })
        #expect(HangReportSignposts.categories == ["action", "motion", "key", "switch", "create", "cef", "launch"])
    }

    /// One detector sample, as schema 3 writes it (first in `hangs`).
    static let blockingSample = #"{"blocking":{"context":"main","kind":"file-io"},"durationMs":0,"frames":[{"image":"cmux NEXT Nightly","offset":768,"uuid":"3F0C9E43-7A61-3C8E-9C1A-2B7F5D0E9A11"},{"image":"other"}],"kind":"blocking","source":"detector"}"#

    /// Schema 3: schema 2's golden with a blocking sample (hang-reports-DESIGN.md section 4).
    static let golden3 = golden.replacingOccurrences(of: #""hangs":["#, with: #""hangs":["# + blockingSample + ",")
        .replacingOccurrences(of: #""schema":2"#, with: #""schema":3"#)

    @Test func theSchema3GoldenRoundTripsToTheSameBytes() throws {
        let report = try JSONDecoder().decode(HangReport.self, from: Data(Self.golden3.utf8))
        let encoded = try HangReport.encoder.encode(report)

        #expect(report.schema == HangReport.WireSchema.v3.rawValue)
        #expect(report.hangs.first?.blocking == HangSample.Blocking(kind: .fileIO, context: .main))
        #expect(String(decoding: encoded, as: UTF8.self) == Self.golden3)
        #expect(PrivacyLeakScanner(forbiddenTerms: HangReportFixtures.forbiddenTerms).findings(in: encoded).isEmpty)
    }

    /// Both goldens pass the server's key and literal rules, and a blocking sample under schema 2 does
    /// not: the case that made the deployed server refuse (and the client drop) the whole report.
    @Test func theGoldensPassTheServerRulesAndABlockingSampleNeedsSchema3() {
        #expect(HangReportServerRules.violations(in: Data(Self.golden.utf8)).isEmpty)
        #expect(HangReportServerRules.violations(in: Data(Self.golden3.utf8)).isEmpty)
        let blockingInSchema2 = Self.golden3.replacingOccurrences(of: #""schema":3"#, with: #""schema":2"#)
        #expect(HangReportServerRules.violations(in: Data(blockingInSchema2.utf8)).count == 3)
    }

    @Test func anUnknownBlockingKindOrContextIsADecodingError() {
        for bad in [#""kind":"file-io""#: #""kind":"disk""#, #""context":"main""#: #""context":"gpu""#] {
            let body = Self.golden3.replacingOccurrences(of: bad.key, with: bad.value)
            #expect(throws: DecodingError.self) { try JSONDecoder().decode(HangReport.self, from: Data(body.utf8)) }
        }
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
    static let golden3MainThread = #"{"active_seconds":5400,"app":{"build":"2123456789012","channel":"nightly","version":"0.70.0"},"counts":{"panes":"6-10","tabs":"31-100","windows":"1","workspaces":"11-30"},"cpuExceptions":[],"day":"2026-10-23","hangs":[],"hardware":{"arch":"arm64","chip":"Apple M4 Pro","cores":14,"memoryGB":48},"installId":"0b8d4a51-6c9e-4f0f-8f53-3c2d7b4f9e20","intervals":[{"buckets":[{"count":1100,"highMs":10,"lowMs":0},{"count":100,"highMs":20,"lowMs":10}],"category":"motion","count":1200,"hitchMsPerS":0.4,"name":"motion.frame"},{"buckets":[{"count":900,"highMs":1,"lowMs":0},{"count":60,"highMs":5,"lowMs":3},{"count":39,"highMs":21,"lowMs":14},{"count":1,"highMs":86400000,"lowMs":10000}],"category":"main","count":1000,"name":"main.turn"},{"buckets":[{"count":40,"highMs":2,"lowMs":1},{"count":1,"highMs":43,"lowMs":30}],"category":"main","count":41,"name":"main.input_queueing"}],"metrics":{"hangTime":[],"launchExtended":[],"launchFirstDraw":[],"launchOptimizedFirstDraw":[],"launchResume":[]},"os":{"version":"15.7.4"},"reportId":"5f1c7c1e-2b9b-4a8e-9c62-0f0d2b0b8a11","schema":3,"stallHistogram":[]}"#

    @Test func theSchemaThreeGoldenRoundTripsAndIsWhatTheBuilderWrites() throws {
        let report = try JSONDecoder().decode(HangReport.self, from: Data(Self.golden3MainThread.utf8))
        #expect(String(decoding: try HangReport.encoder.encode(report), as: UTF8.self) == Self.golden3MainThread)
        #expect(PrivacyLeakScanner(forbiddenTerms: HangReportFixtures.forbiddenTerms).findings(in: Data(Self.golden3MainThread.utf8)).isEmpty)
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

    // MARK: Field data (p09-observability-063)

    /// Schema 3 with `histograms[]` (`[index, count]` buckets), `stability{}`, `blackbox[]` and one earlier launch's
    /// section: the bytes the web decode PR (p09-observability-064) copies to
    /// web/tests/fixtures/hang-report-schema3-field-data.json.
    static let golden3FieldData = #"{"app":{"build":"2123456789012","channel":"nightly","version":"0.70.0"},"blackbox":[{"name":"main.turn","phase":"B","process":"app","t_us":0},{"arg0":7,"name":"daemon.request","phase":"E","process":"daemon","t_us":1250}],"counts":{"panes":"6-10","tabs":"31-100","windows":"1","workspaces":"11-30"},"cpuExceptions":[],"day":"2026-10-23","hangs":[],"hardware":{"arch":"arm64","chip":"Apple M4 Pro","cores":14,"memoryGB":48},"histograms":[{"buckets":[[40,12],[41,3]],"count":15,"max":60000000,"name":"key.frame.terminal","sum":21500,"unit":"us"},{"buckets":[[0,2]],"count":2,"max":256,"name":"cef.helper_exit","sum":0,"unit":"enum"}],"installId":"0b8d4a51-6c9e-4f0f-8f53-3c2d7b4f9e20","intervals":[],"launch_sections":[{"histograms":[{"buckets":[[44,1]],"count":1,"max":3600000,"name":"launch.first_frame.cold","sum":420,"unit":"ms"}],"id":"6f1d2c3b-4a59-4e8d-9c7b-0a1b2c3d4e5f","profile":{"build":"2123456780000","build_day":"2026-10-22","channel":"nightly","os":"15.7.4","version":"0.69.0"},"stability":{"launch":1,"unclean_exit":{"crash":1}}}],"metrics":{"hangTime":[],"launchExtended":[],"launchFirstDraw":[],"launchOptimizedFirstDraw":[],"launchResume":[]},"os":{"version":"15.7.4"},"reportId":"5f1c7c1e-2b9b-4a8e-9c62-0f0d2b0b8a11","schema":3,"stability":{"active_seconds":5400,"child_exit":{"daemon":{"clean":1}},"daemon_unresponsive":{"terminal_io":1},"launch":1},"stallHistogram":[]}"#

    static let scanner = PrivacyLeakScanner(forbiddenTerms: HangReportFixtures.forbiddenTerms)

    @Test func theFieldDataGoldenRoundTripsAndPassesTheScanAndTheServerRules() throws {
        let report = try JSONDecoder().decode(HangReport.self, from: Data(Self.golden3FieldData.utf8))
        let encoded = try HangReport.encoder.encode(report)

        #expect(String(decoding: encoded, as: UTF8.self) == Self.golden3FieldData)
        #expect(report.histograms?.map(\.name) == ["key.frame.terminal", "cef.helper_exit"])
        #expect(report.histograms?.first?.buckets == [.init(index: 40, count: 12), .init(index: 41, count: 3)])
        #expect(report.stability?.childExit == ["daemon": ["clean": 1]])
        #expect(report.stability?.uncleanExit.isEmpty == true)
        #expect(report.blackbox?.last == HangReport.BlackBoxEvent(tUs: 1_250, process: "daemon", name: "daemon.request", phase: "E", arg0: 7))
        #expect(report.launchSections?.first?.profile.buildDay == "2026-10-22")
        #expect(!report.hasNoFindings)
        #expect(Self.scanner.findings(in: encoded).isEmpty)
        #expect(HangReportServerRules.violations(in: encoded).isEmpty)
        // Schema 2's server refuses the new keys: a build writes them only behind hangReportsSchema3.
        let asSchemaTwo = Self.golden3FieldData.replacingOccurrences(of: #""schema":3"#, with: #""schema":2"#)
        #expect(HangReportServerRules.violations(in: Data(asSchemaTwo.utf8)).count == 4)
    }

    @Test func aNonCatalogNameIsRefused() {
        let renamed = Self.golden3FieldData.replacingOccurrences(of: #""name":"key.frame.terminal""#, with: #""name":"key.frame.secret""#)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(HangReport.self, from: Data(renamed.utf8)) }
        #expect(Self.scanner.findings(in: Data(renamed.utf8)) == [PrivacyLeakScanner.Finding(path: "$.histograms[0].name", kind: .notInCatalog)])

        let section = Self.golden3FieldData.replacingOccurrences(of: #""name":"launch.first_frame.cold""#,
                                                                 with: #""name":"launch.first_frame.alice""#)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(HangReport.self, from: Data(section.utf8)) }
        #expect(Self.scanner.findings(in: Data(section.utf8)).map(\.kind) == [.notInCatalog])

        let process = Self.golden3FieldData.replacingOccurrences(of: #""process":"daemon""#, with: #""process":"agent""#)
        #expect(Self.scanner.findings(in: Data(process.utf8)) == [PrivacyLeakScanner.Finding(path: "$.blackbox[1].process", kind: .notInCatalog)])
    }

    static let metricsProfile = MetricsProfile(appVersion: "0.70.0", buildNumber: "2123456789012", channel: "nightly", osVersion: "15.7.4",
                                               hardwareClass: "Mac16,7", buildDay: MetricsProfile.Day(year: 2026, month: 10, day: 20))

    /// A store of `ids` attached to a runtime of its own, and the recorder of that runtime.
    static func metrics(_ ids: [HistogramID], pid: UInt32 = 4_242) -> (store: MetricsStore, metrics: Metrics) {
        let runtime = TraceRuntime(role: .app)
        let store = MetricsStore(role: .app, profile: metricsProfile, pid: pid, catalog: ids)
        store.attach(to: runtime)
        return (store, Metrics(runtime: runtime))
    }

    @Test func theBuilderCapsHistogramsAndBucketsAndReportsSendEachSampleOnce() throws {
        let ids = Array(HistogramID.allCases.filter { $0.unit == .microseconds }.prefix(40))
        try #require(ids.count == 40)
        let (store, metrics) = Self.metrics(ids)
        // 32 buckets per histogram (4 per power of two, 8 powers), each sampled 1 + position times.
        for (position, id) in ids.enumerated() {
            for shift in 0 ..< 8 {
                for sub in 4 ..< 8 {
                    for _ in 0 ... position { metrics.record(id, Int64(sub << shift)) }
                }
            }
        }

        let first = HangReportBuilder.fieldData(store.delta()).histograms
        #expect(first.count == HangReport.maxFieldHistograms)
        #expect(Set(first.map(\.name)) == Set(ids.suffix(HangReport.maxFieldHistograms).map(\.name)))
        #expect(first.allSatisfy { $0.buckets.count == HangReport.maxFieldBuckets && $0.unit == "us" && $0.max == 60_000_000 })
        #expect(first.allSatisfy { histogram in histogram.count == histogram.buckets.reduce(0) { $0 + $1.count } })

        var counts: [String: UInt64] = [:]
        var sums: [String: UInt64] = [:]
        var reports = 0
        while !store.delta().isEmpty, reports < 8 {
            let delta = store.delta()
            let histograms = HangReportBuilder.fieldData(delta).histograms
            #expect(histograms.count <= HangReport.maxFieldHistograms)
            #expect(histograms.allSatisfy { $0.buckets.count <= HangReport.maxFieldBuckets })
            for histogram in histograms {
                counts[histogram.name, default: 0] += histogram.count
                sums[histogram.name, default: 0] += histogram.sum
            }
            store.markLogged(HangReportBuilder.sentDelta(delta, histograms: histograms))
            reports += 1
        }
        #expect(store.delta().isEmpty)
        // (4 + 5 + 6 + 7) * (1 + 2 + ... + 128): every sample sent once, the split sums add up.
        for (position, id) in ids.enumerated() {
            #expect(counts[id.name] == UInt64(32 * (position + 1)))
            #expect(sums[id.name] == UInt64(22 * 255 * (position + 1)))
        }
    }

    @Test func stabilityCountsComeFromTheirHistogramsAndAreMarkedSentWhole() throws {
        let ids: [HistogramID] = [.stabilityLaunch, .stabilityActiveSeconds, .stabilityUncleanExit, .stabilityChildExit(.daemon),
                                  .stabilityChildExit(.renderer), .daemonUnresponsive, .mainTurn]
        let (store, metrics) = Self.metrics(ids)
        metrics.record(.stabilityLaunch, 1)
        metrics.record(.stabilityLaunch, 1)
        metrics.record(.stabilityActiveSeconds, 300)
        metrics.record(.stabilityActiveSeconds, 120)
        metrics.record(.stabilityUncleanExit, HistogramID.UncleanExit.crash.rawValue)
        metrics.record(.stabilityUncleanExit, HistogramID.UncleanExit.systemShutdown.rawValue)
        metrics.record(.stabilityChildExit(.daemon), HistogramID.ChildExit.panic.rawValue)
        metrics.record(.stabilityChildExit(.renderer), HistogramID.ChildExit.oom.rawValue)
        metrics.record(.stabilityChildExit(.renderer), HistogramID.ChildExit.oom.rawValue)
        let terminalIO = try #require(HistogramID.MethodClass.allCases.firstIndex(of: .terminalIO))
        metrics.record(.daemonUnresponsive, Int64(terminalIO))
        metrics.record(.mainTurn, 100)

        let delta = store.delta()
        let (histograms, stability) = HangReportBuilder.fieldData(delta)
        #expect(histograms.map(\.name) == ["main.turn"])
        #expect(stability.launch == 2)
        #expect(stability.activeSeconds == 420)
        #expect(stability.uncleanExit == ["crash": 1, "system_shutdown": 1])
        #expect(stability.childExit == ["daemon": ["panic": 1], "renderer": ["oom": 2]])
        #expect(stability.daemonUnresponsive == ["terminal_io": 1])

        // A report whose body cap cut every histogram still sends (and marks) the stability counts.
        store.markLogged(HangReportBuilder.sentDelta(delta, histograms: []))
        #expect(store.delta().histograms.map(\.name) == ["main.turn"])
    }

    /// One black-box record of `name`.
    static func record(_ name: String, process: TraceRuntime.Role = .app, category: UInt8 = 0,
                       phase: TraceRecord.Phase = .instant, at time: UInt64) -> TraceBlackBoxUpload.Record {
        TraceBlackBoxUpload.Record(process: process, timestamp: time,
                                   name: TraceBlackBoxUpload.Record.Name(text: name, kind: .catalog, categoryBit: category),
                                   phaseCode: phase.rawValue, arg0: time, arg1: 3)
    }

    @Test func plantedKeyRecordsNeverReachTheBlackBox() throws {
        var records: [TraceBlackBoxUpload.Record] = []
        for index in 0 ..< 100 {
            let time = UInt64(index) * 10_000 + 5_000_000
            records.append(Self.record("key.frame", category: 1, phase: .begin, at: time))
            records.append(Self.record("holder.pty.read", process: .holder, category: 6, at: time + 1))
            records.append(Self.record("main.turn", phase: .flowOut, at: time + 2))
        }
        for index in 0 ..< 10 {
            let time = UInt64(index) * 100_000 + 5_000_000
            records.append(Self.record("main.turn", phase: .begin, at: time + 3))
            records.append(Self.record("daemon.request", process: .daemon, phase: .end, at: time + 4))
        }

        let report = HangReportFixtures.builder(wireSchema: .v3).build(
            context: HangReportFixtures.context(), watchdog: StallAggregate(), metricKit: [],
            fieldData: HangReportBuilder.FieldDataInput(blackbox: records))
        let events = try #require(report.blackbox)
        #expect(events.count == 20)
        #expect(events.allSatisfy { !$0.name.hasPrefix("key.") && !$0.name.contains("pty") && $0.phase != "s" })
        #expect(Set(events.map(\.process)) == ["app", "daemon"])
        #expect(events.first?.tUs == 0)
        #expect(events.last?.tUs == 900)
        // A black box alone is context: the report has no findings and is not sent for it.
        #expect(report.hasNoFindings)
        let encoded = try HangReport.encoder.encode(report)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("key."))
        #expect(Self.scanner.findings(in: encoded).isEmpty)

        let schemaTwo = HangReportFixtures.builder(wireSchema: .v2).build(
            context: HangReportFixtures.context(), watchdog: StallAggregate(), metricKit: [],
            fieldData: HangReportBuilder.FieldDataInput(blackbox: records))
        #expect(schemaTwo.blackbox == nil)
    }

    /// A histogram at the caps: 24 buckets of large counts.
    static func fullHistogram(_ name: String) -> HangReport.FieldHistogram {
        HangReport.FieldHistogram(name: name, unit: "us", buckets: (0 ..< HangReport.maxFieldBuckets).map {
            HangReport.FieldHistogram.Bucket(index: 100 + $0, count: 999_999_999_999)
        }, count: 23_999_999_999_976, sum: .max, max: 60_000_000)
    }

    @Test func aFullCapBodyFitsFortyEightKiBDroppingTheBlackBoxFirst() throws {
        var stability = HangReport.Stability()
        stability.launch = 999_999
        stability.activeSeconds = 999_999_999
        stability.uncleanExit = Dictionary(uniqueKeysWithValues: HistogramID.UncleanExit.allCases.map {
            (HangReportBuilder.uncleanExitName($0), UInt64(999_999))
        })
        let exits = Dictionary(uniqueKeysWithValues: HistogramID.ChildExit.allCases.map { (HangReportBuilder.childExitName($0), UInt64(999_999)) })
        stability.childExit = Dictionary(uniqueKeysWithValues: HistogramID.ProcessKind.allCases.map { ($0.rawValue, exits) })
        stability.daemonUnresponsive = Dictionary(uniqueKeysWithValues: HistogramID.MethodClass.allCases.map { ($0.rawValue, UInt64(999_999)) })
        let names = Array(HangReport.histogramCatalog.sorted().prefix(HangReport.maxFieldHistograms))

        var report = Self.report(.v3, mainThread: nil)
        report.histograms = names.map(Self.fullHistogram)
        report.stability = stability
        report.launchSections = [HangReport.LaunchSection(
            id: HangReportBuilder.sectionID("app-1111-1792800000000000000"),
            profile: HangReport.LaunchSection.Profile(version: "0.69.0", build: "2123456780000", channel: "nightly", os: "15.7.4",
                                                      buildDay: "2026-10-22"),
            histograms: names.map(Self.fullHistogram), stability: stability)]
        report.blackbox = (0 ..< UInt64(TraceBlackBoxUpload.maxEvents)).map {
            HangReport.BlackBoxEvent(tUs: $0 * 1_000_000, process: "terminal_host", name: "daemon.dispatch.queue", phase: "B",
                                     arg0: .max - $0, arg1: .max)
        }
        report.hangs = [HangSample(source: .watchdog, kind: .stall, durationMs: 300, frames: [.other]),
                        HangSample(source: .watchdog, kind: .stall, durationMs: 280, frames: [.other])]
        #expect(try HangReport.encoder.encode(report).count > HangReport.WireSchema.v3.maxBodyBytes)
        #expect(Self.scanner.findings(in: try HangReport.encoder.encode(report)).isEmpty)

        let fitted = HangReportService.fitted(report)
        let body = try HangReport.encoder.encode(fitted)
        #expect(body.count <= 48 * 1_024)
        #expect(HangReport.WireSchema.v3.maxBodyBytes == 48 * 1_024)
        // The black box went first, from its oldest events; everything else stayed.
        let kept = try #require(fitted.blackbox)
        #expect(kept.count < TraceBlackBoxUpload.maxEvents)
        #expect(kept.last == report.blackbox?.last)
        #expect(fitted.hangs == report.hangs)
        #expect(fitted.histograms == report.histograms)
        #expect(fitted.launchSections == report.launchSections)
        #expect(fitted.stability == report.stability)
        #expect(HangReportServerRules.violations(in: body).isEmpty)
    }

    @Test func aBodyTooLargeWithoutABlackBoxKeepsTheFirstSectionAndEveryHistogram() throws {
        var report = Self.report(.v3, mainThread: nil)
        let names = Array(HangReport.histogramCatalog.sorted().prefix(HangReport.maxFieldHistograms))
        report.histograms = names.map(Self.fullHistogram)
        let profile = HangReport.LaunchSection.Profile(version: "0.69.0", build: "1", channel: "nightly", os: "15.7.4", buildDay: "2026-10-22")
        report.launchSections = (0 ..< 3).map { index in
            HangReport.LaunchSection(id: HangReportBuilder.sectionID("launch-\(index)"), profile: profile,
                                     histograms: names.map(Self.fullHistogram), stability: nil)
        }
        let fitted = HangReportService.fitted(report)
        #expect(try HangReport.encoder.encode(fitted).count <= HangReport.WireSchema.v3.maxBodyBytes)
        #expect(fitted.launchSections?.map(\.id) == [HangReportBuilder.sectionID("launch-0")])
        #expect(fitted.histograms == report.histograms)
    }

    @Test func aBodyTooLargeCutsTheFieldDataALaterReportCarriesBeforeAnyHang() throws {
        let names = Array(HangReport.histogramCatalog.sorted().prefix(HangReport.maxFieldHistograms))
        var stability = HangReport.Stability()
        stability.launch = 3
        var report = Self.report(.v3, mainThread: nil)
        report.histograms = names.map(Self.fullHistogram)
        report.stability = stability
        report.launchSections = [HangReport.LaunchSection(
            id: HangReportBuilder.sectionID("launch-0"),
            profile: HangReport.LaunchSection.Profile(version: "0.69.0", build: "1", channel: "nightly", os: "15.7.4", buildDay: "2026-10-22"),
            histograms: names.map(Self.fullHistogram), stability: stability)]
        report.hangs = (0 ..< HangReport.maxHangs).map { index in
            HangSample(source: .watchdog, kind: .hang, durationMs: 5_000 - index,
                       frames: Array(repeating: .other, count: HangSample.maxFrames))
        }
        let limit = HangReport.WireSchema.v3.maxBodyBytes
        #expect(try HangReport.encoder.encode(report).count > limit)

        let fitted = HangReportService.fitted(report)
        #expect(try HangReport.encoder.encode(fitted).count <= limit)
        // Drained hangs are gone once cut; a cut section or histogram stays unsent for a later report.
        #expect(fitted.hangs == report.hangs)
        #expect(fitted.stability == report.stability)
        #expect((fitted.launchSections?.count ?? 0) + (fitted.histograms?.count ?? 0) < 1 + names.count)
    }

    // MARK: Features (p12-perf-process-151)

    static let features = HangReport.FeatureState(hash: "363b2a8f1f789985", nonDefault: [
        HangReport.FeatureEntry(name: "hangReportsSchema3", state: "on", source: "env"),
        HangReport.FeatureEntry(name: "vsyncHub", state: "off", source: "remote"),
    ])

    static func report(_ schema: HangReport.WireSchema, features: HangReport.FeatureState?) -> HangReport {
        var context = HangReportFixtures.context()
        context.features = features
        return HangReportFixtures.builder(wireSchema: schema).build(context: context, watchdog: StallAggregate(), metricKit: [])
    }

    /// Schema 3 with the launch's features hash and the two features an override decided.
    static let golden3Features = #"{"app":{"build":"70123","channel":"nightly","version":"0.70.0"},"counts":{"panes":"11-30","tabs":"31-100","windows":"1","workspaces":"11-30"},"cpuExceptions":[],"day":"2026-10-23","features":[{"name":"hangReportsSchema3","source":"env","state":"on"},{"name":"vsyncHub","source":"remote","state":"off"}],"features_hash":"363b2a8f1f789985","hangs":[],"hardware":{"arch":"arm64","chip":"Apple M4 Pro","cores":14,"memoryGB":48},"installId":"0b8d4a51-6c9e-4f0f-8f53-3c2d7b4f9e20","intervals":[],"metrics":{"hangTime":[],"launchExtended":[],"launchFirstDraw":[],"launchOptimizedFirstDraw":[],"launchResume":[]},"os":{"version":"15.7.4"},"reportId":"5f1c7c1e-2b9b-4a8e-9c62-0f0d2b0b8a11","schema":3,"stallHistogram":[]}"#

    @Test func schemaThreeSendsTheFeaturesHashAndTheNonDefaultFeatures() throws {
        let report = Self.report(.v3, features: Self.features)
        #expect(report.featuresHash == "363b2a8f1f789985")
        #expect(report.features == Self.features.nonDefault)
        let encoded = try HangReport.encoder.encode(report)
        #expect(String(decoding: encoded, as: UTF8.self) == Self.golden3Features)
        #expect(try JSONDecoder().decode(HangReport.self, from: encoded) == report)
        #expect(HangReportServerRules.violations(in: encoded).isEmpty)
        #expect(PrivacyLeakScanner(forbiddenTerms: HangReportFixtures.forbiddenTerms).findings(in: encoded).isEmpty)
        // The features describe a report; they are not a finding of their own.
        #expect(report.hasNoFindings)
    }

    @Test func schemaTwoCarriesNoFeatures() throws {
        let report = Self.report(.v2, features: Self.features)
        #expect(report == Self.report(.v2, features: nil))
        let encoded = try HangReport.encoder.encode(report)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("features"))
        #expect(HangReportServerRules.violations(in: encoded).isEmpty)
        let featuresInSchema2 = Self.golden3Features.replacingOccurrences(of: #""schema":3"#, with: #""schema":2"#)
        #expect(HangReportServerRules.violations(in: Data(featuresInSchema2.utf8)).count == 2)
    }

    @Test func aReportWithoutFeaturesStillDecodesAndOmitsThem() throws {
        let older = try JSONDecoder().decode(HangReport.self, from: Data(Self.golden3.utf8))
        #expect(older.featuresHash == nil && older.features == nil)
        #expect(String(decoding: try HangReport.encoder.encode(older), as: UTF8.self) == Self.golden3)
        let none = Self.report(.v3, features: nil)
        #expect(!String(decoding: try HangReport.encoder.encode(none), as: UTF8.self).contains("features"))
    }

    @Test func theLaunchsFeatureListBecomesTheReportsFeatures() {
        let schema3 = Feature(index: 0, name: "hangReportsSchema3", owner: "PL-test", description: "A test feature.", kind: .killSwitch,
                              process: .app, chromiumFeature: nil, defaults: FeatureDefaults(all: false), expires: nil, params: [],
                              stories: [], sticky: false, runtimeMutable: false)
        let list = FeatureList(registry: FeatureRegistry([schema3]), channel: .nightly,
                               overrides: FeatureOverrides(environmentEnabled: ["hangReportsSchema3"]))
        let state = HangReport.FeatureState(list.fieldState)
        #expect(state.hash == list.fieldState.hash)
        #expect(state.nonDefault == [HangReport.FeatureEntry(name: "hangReportsSchema3", state: "on", source: "env")])
        #expect(Self.report(.v3, features: state).features == state.nonDefault)
    }

    @Test func onlyRegistryNamesStatesAndOverrideSourcesAreSent() {
        let entries = [
            HangReport.FeatureEntry(name: "vsyncHub", state: "on", source: "trial"),
            HangReport.FeatureEntry(name: "/Users/alice", state: "on", source: "env"),
            HangReport.FeatureEntry(name: "vsync hub", state: "on", source: "env"),
            HangReport.FeatureEntry(name: "vsyncHub", state: "enabled", source: "env"),
            HangReport.FeatureEntry(name: "vsyncHub", state: "on", source: "default"),
        ]
        let report = Self.report(.v3, features: HangReport.FeatureState(hash: "0123456789abcdef", nonDefault: entries))
        #expect(report.features == [entries[0]])
        for hash in ["0123456789ABCDEF", "0123456789abcde", "0123456789abcdef0", "/Users/alice/x.y"] {
            let bad = Self.report(.v3, features: HangReport.FeatureState(hash: hash, nonDefault: [entries[0]]))
            #expect(bad.featuresHash == nil && bad.features == nil)
        }
        let many = (0 ..< HangReport.maxFeatures + 5).map { HangReport.FeatureEntry(name: "feature\($0)", state: "off", source: "remote") }
        let capped = Self.report(.v3, features: HangReport.FeatureState(hash: "0123456789abcdef", nonDefault: many))
        #expect(capped.features == Array(many.prefix(HangReport.maxFeatures)))
    }

    // MARK: Blocking sites (p12-perf-process-226)

    /// Two main-thread sites and a pool site, as the detector lists them; only the main thread's are sent.
    static let detectorSites = [
        BlockingSite(kind: .fileIO, location: "CmuxNextApp/WorkspaceStore.swift:42", count: 7, totalNanos: 12_500_000),
        BlockingSite(kind: .sqlite, location: "CmuxNextSidebar/SidebarModel.swift:9", count: 3),
        BlockingSite(kind: .fileIO, location: "CmuxNextApp/WorkspaceStore.swift:42", count: 5, context: .pool),
    ]
    /// The ids are SHA-256 of `Module/File.swift:line` (first 8 bytes), as `lab.py field --sites-from` computes them.
    static let blockingSitesJSON = #""blocking_sites":[{"count":7,"kind":"file-io","site":"8ef2dbd38483c034","total_ms":12},{"count":3,"kind":"sqlite","site":"2fc36eeebd7c605e","total_ms":0}]"#

    static func report(_ schema: HangReport.WireSchema, blockingSites: [HangReport.BlockingSiteCount]?) -> HangReport {
        HangReportFixtures.builder(wireSchema: schema).build(context: HangReportFixtures.context(), watchdog: StallAggregate(),
                                                             metricKit: [], blockingSites: blockingSites)
    }

    /// The privacy rule: a site leaves the Mac as its hash, kind and counts; no path, module or file name.
    @Test func schemaThreeSendsTheMainThreadsBlockingSitesByHashedIDWithNoPath() throws {
        let ledger = BlockingSiteLedger(sites: { BlockingDetector.MainThreadRead(sites: Self.detectorSites) })
        let report = Self.report(.v3, blockingSites: ledger.take().sites)
        let body = try HangReport.encoder.encode(report)
        let text = String(decoding: body, as: UTF8.self)
        #expect(text.contains(Self.blockingSitesJSON))
        for name in ["/", ".swift", "CmuxNextApp", "CmuxNextSidebar", "WorkspaceStore", "SidebarModel"] { #expect(!text.contains(name)) }
        #expect(try JSONDecoder().decode(HangReport.self, from: body) == report)
        #expect(HangReportServerRules.violations(in: body).isEmpty)
        #expect(PrivacyLeakScanner(forbiddenTerms: HangReportFixtures.forbiddenTerms).findings(in: body).isEmpty)
        #expect(!report.hasNoFindings)
        let inSchema2 = text.replacingOccurrences(of: #""schema":3"#, with: #""schema":2"#)
        #expect(HangReportServerRules.violations(in: Data(inSchema2.utf8)) == ["report.blocking_sites is not accepted"])
    }

    @Test func schemaTwoCarriesNoBlockingSitesAndSchemaThreeOnlyWellFormedOnes() {
        let valid = HangReport.BlockingSiteCount(site: "8ef2dbd38483c034", kind: "file-io", count: 2, totalMs: 1)
        #expect(Self.report(.v2, blockingSites: [valid]).blockingSites == nil)
        let bad = [HangReport.BlockingSiteCount(site: "CmuxNextApp/A.swift:1", kind: "file-io", count: 9, totalMs: 0),
                   HangReport.BlockingSiteCount(site: "8EF2DBD38483C034", kind: "file-io", count: 9, totalMs: 0),
                   HangReport.BlockingSiteCount(site: "2fc36eeebd7c605e", kind: "disk", count: 9, totalMs: 0),
                   HangReport.BlockingSiteCount(site: "2fc36eeebd7c605e", kind: "sqlite", count: 0, totalMs: 0)]
        #expect(Self.report(.v3, blockingSites: bad + [valid]).blockingSites == [valid])
        #expect(Self.report(.v3, blockingSites: bad).blockingSites == nil)
        let many = (0 ..< HangReport.maxBlockingSites + 5).map {
            HangReport.BlockingSiteCount(site: String(format: "%016lx", $0), kind: "sleep", count: $0 + 1, totalMs: 0)
        }
        #expect(Self.report(.v3, blockingSites: many).blockingSites?.map(\.count) == Array((6 ... HangReport.maxBlockingSites + 5).reversed()))
    }
}
