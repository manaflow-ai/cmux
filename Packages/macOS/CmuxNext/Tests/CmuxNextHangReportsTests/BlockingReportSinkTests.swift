#if DEBUG || CMUX_BLOCKING_CHECKS
import CmuxNextCompat
@testable import CmuxNextHangReports
import CmuxNextMetrics
import CmuxNextTrace
import Foundation
import Testing

/// The blocking detector's sink (p02-threads-008): every site to the hang report collector; to crash
/// reporting only with consent, at most 5 per launch and 1 per site per 24 h, the last-sent times
/// saved for the next launch; the event names no path; each main-thread site is one `blocking.violations` sample
/// (p09-observability-089). Compiled with the sink only (Debug and `CMUX_BLOCKING_CHECKS`).
struct BlockingReportSinkTests {
    private static let image = UUID(uuidString: HangReportFixtures.appUUID) ?? UUID()
    private static let now = Date(timeIntervalSince1970: 2_000_000_000)

    private static func violation(_ offset: UInt64) -> BlockingViolation {
        BlockingViolation(kind: .fileIO, frames: [BlockingFrame(imageUUID: image, offset: offset)])
    }

    private static func sink(consented: Bool, lastSent: [String: Date] = [:],
                             violations: BlockingViolationCounter? = nil) -> (BlockingReportSink, BlockingSinkRecorder) {
        let recorder = BlockingSinkRecorder()
        let at = now
        let sink = BlockingReportSink(
            collector: recorder.collector,
            violations: violations,
            nonFatal: BlockingReportSink.NonFatal(consented: { consented }, send: { recorder.send($0) }),
            store: BlockingReportSink.LastSentStore(load: { lastSent }, save: { recorder.save($0) }),
            now: { at })
        return (sink, recorder)
    }

    @Test func withoutConsentNothingIsSentButTheReportGetsTheSite() {
        let (sink, recorder) = Self.sink(consented: false)
        sink.record(Self.violation(1))

        #expect(recorder.sent.isEmpty)
        #expect(recorder.saved.isEmpty)
        #expect(recorder.collector.snapshot().blocking.count == 1)
    }

    @Test func withConsentFiveSitesPerLaunch() {
        let (sink, recorder) = Self.sink(consented: true)
        for offset in 0..<7 { sink.record(Self.violation(UInt64(offset))) }

        #expect(recorder.sent.count == BlockingReportBudget.perLaunch)
        #expect(recorder.saved.last?.count == BlockingReportBudget.perLaunch)
    }

    @Test func aSiteSentInTheLast24HoursIsNotSentAgain() {
        let held = BlockingReportBudget.site(of: Self.violation(9))
        let fresh = BlockingReportBudget.site(of: Self.violation(10))
        let (sink, recorder) = Self.sink(consented: true, lastSent: [held: Self.now.addingTimeInterval(-3_600)])
        sink.record(Self.violation(9))
        sink.record(Self.violation(10))
        sink.record(Self.violation(10))

        #expect(recorder.sent.map { $0.fingerprint.last } == [fresh])
        #expect(recorder.saved.last?.keys.sorted() == [held, fresh].sorted())
    }

    @Test func theEventNamesTheKindContextAndFramesOnly() throws {
        let (sink, recorder) = Self.sink(consented: true)
        sink.record(BlockingViolation(kind: .syncWait, frames: [BlockingFrame(imageUUID: Self.image, offset: 0x1F0)]))

        let event = try #require(recorder.sent.first)
        #expect(event.message == "main-thread blocking: sync-wait")
        #expect(event.tags == ["blocking_kind": "sync-wait", "blocking_context": "main"])
        #expect(event.extra == ["frames": "\(HangReportFixtures.appUUID)+0x1f0"])
        #expect(event.type == "MainThreadBlocking")
        #expect(event.fingerprint.first == "main-thread-blocking")
    }

    /// `blocking.violations`: one sample of 1 per new main-thread site, with or without consent; a pool site counts none.
    @Test func eachMainThreadSiteIsOneBlockingViolationsSample() throws {
        let (store, metrics) = HangReportWireFormatTests.metrics([.blockingViolations])
        let (sink, _) = Self.sink(consented: false, violations: BlockingViolationCounter(metrics: metrics))
        sink.record(Self.violation(1))
        sink.record(Self.violation(2))
        sink.record(BlockingViolation(kind: .fileIO, context: .pool, frames: [BlockingFrame(imageUUID: Self.image, offset: 3)]))

        let violations = try #require(store.delta().histograms.first { $0.name == HistogramID.blockingViolations.name })
        #expect(violations.count == 2)
        #expect(violations.sum == 2)
    }

    /// The detector replays the launch's early sites to the sink before the app's store is attached on the files lane:
    /// they are kept, recorded when the store is attached (`MetricsStore.startApp`'s `attached`), and a later site
    /// counts at once.
    @Test func mainThreadSitesBeforeTheStoreIsAttachedAreCounted() throws {
        let runtime = TraceRuntime(role: .app)
        let counter = BlockingViolationCounter(metrics: Metrics(runtime: runtime))
        let (sink, _) = Self.sink(consented: false, violations: counter)
        sink.record(Self.violation(1))
        sink.record(Self.violation(2))
        counter.metricsAttached()

        let store = MetricsStore(role: .app, profile: HangReportWireFormatTests.metricsProfile, pid: 4_243, catalog: [.blockingViolations])
        try #require(store.delta().histograms.isEmpty)
        store.attach(to: runtime)
        counter.metricsAttached()
        let early = try #require(store.delta().histograms.first { $0.name == HistogramID.blockingViolations.name })
        #expect(early.count == 2)

        sink.record(Self.violation(3))
        counter.metricsAttached()
        let all = try #require(store.delta().histograms.first { $0.name == HistogramID.blockingViolations.name })
        #expect(all.count == 3)
        #expect(all.sum == 3)
    }

    /// Without the attach call, the first site after the store is attached records the kept ones with it.
    @Test func theFirstSiteAfterTheStoreIsAttachedRecordsTheKeptOnes() throws {
        let runtime = TraceRuntime(role: .app)
        let counter = BlockingViolationCounter(metrics: Metrics(runtime: runtime))
        let (sink, _) = Self.sink(consented: false, violations: counter)
        sink.record(Self.violation(1))
        let store = MetricsStore(role: .app, profile: HangReportWireFormatTests.metricsProfile, pid: 4_244, catalog: [.blockingViolations])
        store.attach(to: runtime)
        sink.record(Self.violation(2))

        let violations = try #require(store.delta().histograms.first { $0.name == HistogramID.blockingViolations.name })
        #expect(violations.count == 2)
    }

    /// A pool thread's site (p02-threads-005's context) is reported as one, in the sample and the event.
    @Test func aPoolSiteIsTaggedPool() throws {
        let (sink, recorder) = Self.sink(consented: true)
        let pool = BlockingViolation(kind: .fileIO, context: .pool, frames: [BlockingFrame(imageUUID: Self.image, offset: 0x2A)])
        sink.record(pool)

        let sample = try #require(recorder.collector.snapshot().blocking.first)
        #expect(sample.blocking == HangSample.Blocking(kind: .fileIO, context: .pool))
        let event = try #require(recorder.sent.first)
        #expect(event.message == "pool-thread blocking: file-io")
        #expect(event.type == "PoolThreadBlocking")
        #expect(event.tags["blocking_context"] == "pool")
        #expect(event.fingerprint.first == "pool-thread-blocking")
        // The same stack on the main thread is another site.
        var main = pool
        main.context = .main
        #expect(BlockingReportBudget.site(of: main) != BlockingReportBudget.site(of: pool))
    }
}

/// What the sink sent and saved, and the collector it fed.
private final class BlockingSinkRecorder: Sendable {
    let collector = HangReportCollector(resolve: { _ in [] }, resolveBlocking: { $0.map { _ in .other } }, schedule: { $0() })
    private let sends = Mutex<[BlockingReportSink.NonFatalEvent]>([])
    private let saves = Mutex<[[String: Date]]>([])

    var sent: [BlockingReportSink.NonFatalEvent] { sends.withLock { $0 } }
    var saved: [[String: Date]] { saves.withLock { $0 } }

    func send(_ event: BlockingReportSink.NonFatalEvent) {
        sends.withLock { $0.append(event) }
    }

    func save(_ times: [String: Date]) {
        saves.withLock { $0.append(times) }
    }
}
#endif
