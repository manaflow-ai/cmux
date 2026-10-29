import CmuxNextCompat
import CmuxNextMetrics
@testable import CmuxNextSignposts
@testable import CmuxNextTrace
import Testing

/// A WebKit content-process end and a Chromium "Page unresponsive" span are each a `crash` ring
/// record, a stability count in the metrics file and a rate-limited report: 3 ends are 3 counts and 1 report, and the
/// next report after the hour carries the count since the last. Each test has its own runtime, store and clock.
@MainActor
struct RendererStabilityTests {
    /// `CLOCK_UPTIME_RAW` as a counter the test moves, and the ring records the runtime writes.
    private nonisolated final class Rig: Sendable {
        private let nanos = Atomic<UInt64>(5_000_000_000)
        private let log: RecordLog
        /// The runtime the stability events record into, with the `crash` category on: its ring records land in
        /// ``records``, its samples in ``store``.
        let recording: TraceRuntime
        let store: MetricsStore

        init() {
            let profile = MetricsProfile(appVersion: "1.0", buildNumber: "1", channel: "test", osVersion: "26.1.0",
                                         hardwareClass: "Mac16,10", buildDay: MetricsProfile.Day(year: 2026, month: 10, day: 27))
            store = MetricsStore(role: .app, profile: profile)
            let log = RecordLog()
            self.log = log
            recording = TraceRuntime(role: .app, clock: TraceClock(), stubRecorder: { record in log.append(record) })
            store.attach(to: recording)
            recording.setCategoryMask(1 << UInt64(SignpostCategory.crash.traceBit))
        }

        var clock: TraceClock {
            TraceClock(reader: .init(uptimeNanos: { [self] in nanos.load(ordering: .relaxed) }, continuousNow: { ContinuousClock.now }))
        }

        var records: [TraceRuntime.StubRecord] { log.records }

        func advance(_ duration: Duration) {
            let (seconds, attoseconds) = duration.components
            _ = nanos.wrappingAdd(UInt64(seconds) * 1_000_000_000 + UInt64(attoseconds / 1_000_000_000), ordering: .relaxed)
        }

        func histogram(_ id: HistogramID) -> MetricsDelta.Histogram? {
            store.delta().histograms.first { $0.name == id.name }
        }
    }

    /// The ring records a runtime wrote, in order.
    private nonisolated final class RecordLog: Sendable {
        private let state = Mutex<[TraceRuntime.StubRecord]>([])

        var records: [TraceRuntime.StubRecord] { state.withLock { $0 } }

        func append(_ record: TraceRuntime.StubRecord) { state.withLock { $0.append(record) } }
    }

    private final class Reports {
        var all: [RendererStability.Report] = []
    }

    private static func stability(_ rig: Rig, _ reports: Reports?) -> RendererStability {
        guard let reports else { return RendererStability(trace: rig.recording, clock: rig.clock) }
        return RendererStability(trace: rig.recording, clock: rig.clock) { reports.all.append($0) }
    }

    @Test("3 content ends in a minute are 3 counts, 3 ring instants and 1 report")
    func threeEndsAreOneReportAndThreeCounts() throws {
        let rig = Rig()
        let reports = Reports()
        let stability = Self.stability(rig, reports)
        for _ in 0 ..< 3 {
            stability.webKitContentEnded(on: .browserTab, process: nil)
            rig.advance(.seconds(20))
        }

        #expect(reports.all == [RendererStability.Report(kind: .contentEnded, engine: .webKit, surface: .browserTab, count: 1,
                                                          unresponsiveMilliseconds: nil, ending: nil)])
        let ends = try #require(rig.histogram(.stabilityChildExit(.webkit)))
        #expect(ends.count == 3)
        let signal = HistogramID.stabilityChildExit(.webkit).layout.bucketIndex(of: HistogramID.ChildExit.signal.rawValue)
        #expect(ends.buckets.map(\.index) == [signal].compactMap { $0 }, "every end counts as ended by a signal")
        let pages = try #require(rig.histogram(.stabilityRenderer(.contentEnd, .webkit)))
        let browserTab = HistogramID.stabilityRenderer(.contentEnd, .webkit).layout.bucketIndex(of: HistogramID.RendererSurface.browserTab.rawValue)
        #expect(pages.count == 3 && pages.buckets.map(\.index) == [browserTab].compactMap { $0 }, "3 browser-tab page ends")
        let instants = rig.records.filter { $0.name == SignpostName.crashWebContentEnd.rawValue }
        #expect(instants.count == 3)
        #expect(instants.allSatisfy { $0.phase == .instant && $0.arg0 == RendererStability.Surface.browserTab.rawValue })
        #expect(instants.allSatisfy { $0.categoryBit == SignpostCategory.crash.traceBit })
    }

    @Test("Grouped pages of one ended process are one process end and a page end each, by surface")
    func onePageEndEachAndOneProcessEnd() throws {
        let rig = Rig()
        let stability = Self.stability(rig, nil)
        stability.webKitContentCommitted(in: 4242)
        stability.webKitContentEnded(on: .page, process: 4242)
        stability.webKitContentEnded(on: .page, process: 4242)
        stability.webKitContentEnded(on: .warmup, process: 4242)

        #expect(try #require(rig.histogram(.stabilityChildExit(.webkit))).count == 1, "WebKit told 3 pages of one process")
        let pages = try #require(rig.histogram(.stabilityRenderer(.contentEnd, .webkit)))
        #expect(pages.count == 3)
        let layout = HistogramID.stabilityRenderer(.contentEnd, .webkit).layout
        let page = try #require(layout.bucketIndex(of: HistogramID.RendererSurface.page.rawValue))
        let warmup = try #require(layout.bucketIndex(of: HistogramID.RendererSurface.warmup.rawValue))
        #expect(pages.buckets.filter { $0.count > 0 }.map { [$0.index, Int($0.count)] } == [[page, 2], [warmup, 1]])
    }

    @Test("A commit in an ended pid makes its next end another process's")
    func aCommitInAReusedPidCountsItsEndAgain() throws {
        let rig = Rig()
        let stability = Self.stability(rig, nil)
        stability.webKitContentEnded(on: .browserTab, process: 77)
        stability.webKitContentEnded(on: .browserTab, process: 77)
        stability.webKitContentCommitted(in: 77) // the system gave a new WebContent process the same pid
        stability.webKitContentEnded(on: .browserTab, process: 77)
        stability.webKitContentEnded(on: .browserTab, process: nil) // ended before any commit: its own process
        #expect(try #require(rig.histogram(.stabilityChildExit(.webkit))).count == 3)
        #expect(try #require(rig.histogram(.stabilityRenderer(.contentEnd, .webkit))).count == 4)
    }

    @Test("The first event after the hour reports the count since the last report")
    func theNextReportCarriesTheCountSinceTheLast() {
        let rig = Rig()
        let reports = Reports()
        let stability = Self.stability(rig, reports)
        stability.webKitContentEnded(on: .page, process: nil)
        rig.advance(.seconds(60))
        stability.webKitContentEnded(on: .page, process: nil)
        stability.webKitContentEnded(on: .page, process: nil)
        rig.advance(.seconds(3_600))
        stability.webKitContentEnded(on: .page, process: nil)
        #expect(reports.all.map(\.count) == [1, 3], "two ends waited in the hour; the third after it reports all three")
        #expect(reports.all.allSatisfy { $0.surface == .page })
    }

    @Test("Each kind, engine and surface has its own limit")
    func eachSurfaceHasItsOwnLimit() {
        let rig = Rig()
        let reports = Reports()
        let stability = Self.stability(rig, reports)
        stability.webKitContentEnded(on: .browserTab, process: nil)
        stability.webKitContentEnded(on: .page, process: nil)
        stability.webKitContentEnded(on: .warmup, process: nil)
        stability.webKitContentEnded(on: .page, process: nil)
        #expect(reports.all.map(\.surface) == [.browserTab, .page, .warmup])
    }

    @Test("Without a sink the ring and the counts still record")
    func noSinkStillCounts() throws {
        let rig = Rig()
        let stability = Self.stability(rig, nil)
        stability.webKitContentEnded(on: .warmup, process: nil)
        #expect(try #require(rig.histogram(.stabilityChildExit(.webkit))).count == 1)
        #expect(rig.records.map(\.name) == [SignpostName.crashWebContentEnd.rawValue])
        #expect(rig.records.first?.arg0 == RendererStability.Surface.warmup.rawValue)
    }

    @Test("A hang is one AB/AE slice from shown to ended, one renderer.unresponsive_ms sample and its report")
    func aHangIsASliceASampleAndAReport() throws {
        let rig = Rig()
        let reports = Reports()
        let stability = Self.stability(rig, reports)
        let page = ObjectIdentifier(reports)
        stability.unresponsiveShown(page, surface: .browserTab)
        stability.unresponsiveShown(page, surface: .browserTab) // the renderer says it again: one span
        #expect(stability.isUnresponsive(page))
        #expect(rig.histogram(.stabilityRenderer(.unresponsive, .chromium))?.count == 1, "a hang counts at its start")
        rig.advance(.milliseconds(1_500))
        stability.unresponsiveEnded(page, .responsive)
        stability.unresponsiveEnded(page, .closed) // nothing open any more

        #expect(!stability.isUnresponsive(page))
        let hang = try #require(rig.histogram(.rendererUnresponsive))
        #expect(hang.count == 1 && hang.sum == 1_500, "one sample, its length in ms")
        #expect(reports.all == [RendererStability.Report(kind: .unresponsive, engine: .chromium, surface: .browserTab, count: 1,
                                                          unresponsiveMilliseconds: 1_500, ending: .responsive)])
        let slice = rig.records.filter { $0.name == SignpostName.crashRendererUnresponsive.rawValue }
        try #require(slice.count == 2)
        #expect(slice.map(\.phase) == [.asyncBegin, .asyncEnd])
        #expect(slice[0].arg1 == slice[1].arg1 && slice[0].flags.contains(.asyncID))
        #expect(slice[0].arg0 == RendererStability.Surface.browserTab.rawValue)
    }

    @Test("An end with no hang shown records nothing")
    func anEndWithoutAShowRecordsNothing() {
        let rig = Rig()
        let reports = Reports()
        let stability = Self.stability(rig, reports)
        stability.unresponsiveEnded(ObjectIdentifier(reports), .processEnded)
        #expect(reports.all.isEmpty)
        #expect(rig.histogram(.rendererUnresponsive) == nil)
        #expect(rig.records.isEmpty)
    }

    @Test("Two pages hang apart: each span is its own")
    func twoPagesHangApart() throws {
        let rig = Rig()
        let reports = Reports()
        let stability = Self.stability(rig, reports)
        let first = ObjectIdentifier(reports), second = ObjectIdentifier(rig)
        stability.unresponsiveShown(first, surface: .browserTab)
        rig.advance(.milliseconds(200))
        stability.unresponsiveShown(second, surface: .page)
        rig.advance(.milliseconds(300))
        stability.unresponsiveEnded(first, .processEnded)
        stability.unresponsiveEnded(second, .navigated)
        let hang = try #require(rig.histogram(.rendererUnresponsive))
        #expect(hang.count == 2 && hang.sum == 500 + 300)
        #expect(reports.all.map(\.ending) == [.processEnded, .navigated])
        #expect(reports.all.map(\.surface) == [.browserTab, .page])
    }
}
