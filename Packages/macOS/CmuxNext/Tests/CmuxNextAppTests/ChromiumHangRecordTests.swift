@testable import CmuxNextApp
import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextControl
import CmuxNextCrashReporting
import CmuxNextHangReports
import CmuxNextSettings
import Foundation
import Testing

/// p09-observability-106: one Chromium HangWatcher capture is one thread hang, recorded as a watched cmux thread's
/// (Chrome's `HangWatcher::RecordHang` dumps once per capture and names every hung thread in one crash key,
/// base/threading/hang_watcher.cc): the sink hops to a lane, then one `debug.hangs` `thread_hangs` record, one crash
/// report with `hang_source` chromium, one hang-report entry and one last-hang cause, however many threads it names.
struct ChromiumHangRecordTests {
    private static let frames: [UInt] = [0x1000, 0x2000, 0x3000]

    /// A blocked IO thread and its 8 stuck pool workers, most severe first, as the fork's handler lays them out.
    private static func capture() -> [ChromiumHungThread] {
        [ChromiumHungThread(threadID: 700, kind: .io, name: "Chrome_IOThread", overrun: .seconds(3), addresses: frames)]
            + (1...8).map { ChromiumHungThread(threadID: 700 + UInt64($0), kind: .pool, name: "ThreadPoolForegroundWorker",
                                               overrun: .seconds(1), addresses: [UInt($0)]) }
    }

    @Test func oneCaptureOfNineThreadsIsOneRecordOneReportOneEntryAndOneLastHang() throws {
        let rig = Rig()
        let sink = try #require(WatchdogReporting.chromiumHangSink(enabled: true, post: rig.lane.post,
                                                                   record: { [watchdog = rig.watchdog] in
                                                                       watchdog.recordThreadHang($0, threadID: $1) },
                                                                   now: { 10_000_000_000 }))
        sink(Self.capture())
        #expect(rig.watchdog.threadHangs.records().isEmpty, "nothing is recorded on Chromium's HangWatcher thread")
        #expect(rig.lane.pending == 1, "the capture is one lane job")
        rig.lane.runAll()

        let records = rig.watchdog.threadHangs.records()
        #expect(records.count == 1, "one capture is one debug.hangs record")
        let record = try #require(records.first)
        #expect(record.kind == .hang)
        #expect(record.addresses == Self.frames)
        #expect(record.duration == .seconds(3))
        #expect(record.startUptimeNanos == 7_000_000_000, "the first thread's deadline: now less its overrun")
        #expect(record.details["scope"] == .string("chromium.io"))
        #expect(record.details["source"] == .string("chromium"))
        #expect(record.details["thread"] == .string("Chrome_IOThread"))
        #expect(record.details["also_hung"] == .array(Array(repeating: .string("chromium.pool ThreadPoolForegroundWorker"), count: 8)))

        let reports = rig.reports.values
        #expect(reports.count == 1, "one capture is one crash report")
        let report = try #require(reports.first)
        #expect(report.thread == "chromium.io")
        #expect(report.threadKind == "io")
        #expect(report.threadName == "Chrome_IOThread")
        #expect(report.source == ThreadHangEvent.chromiumSource)
        #expect(report.addresses == Self.frames)
        #expect(report.alsoHung.count == 8)

        let entries = rig.collector.drain().threadHangs
        #expect(entries.count == 1, "one capture is one hang-report entry")
        #expect(entries.first?.thread == HangSample.WatchedThread(name: "chromium.io", kind: "io"))

        let causes = rig.lastHangs.values
        #expect(causes.count == 1, "one capture starts one last-hang bundle")
        guard case .threadHang(let hang)? = causes.first else { Issue.record("no thread hang: \(causes)"); return }
        #expect(hang.name == "chromium.io")
        #expect(hang.kind == .io)
        #expect(hang.source == .chromium)
        #expect(hang.addresses == Self.frames)
        #expect(hang.alsoHung.count == 8)
    }

    @Test func aPoolThreadAloneIsRecordedAsChromiumPool() throws {
        let capture = try #require(WatchdogReporting.chromiumThreadHang(
            [ChromiumHungThread(threadID: 9, kind: .pool, name: "", overrun: .seconds(2), addresses: [])], nowNanos: 1_000))
        #expect(capture.threadID == 9)
        #expect(capture.hang.name == "chromium.pool")
        #expect(capture.hang.kindName == "pool")
        #expect(capture.hang.budgetEndNanos == 0, "an overrun past the clock's start does not wrap")
        #expect(capture.hang.alsoHung.isEmpty)
    }

    @Test func anEmptyCaptureRecordsNothing() {
        let rig = Rig()
        let sink = WatchdogReporting.chromiumHangSink(enabled: true, post: rig.lane.post,
                                                      record: { [watchdog = rig.watchdog] in watchdog.recordThreadHang($0, threadID: $1) })
        sink?([])
        rig.lane.runAll()
        #expect(rig.watchdog.threadHangs.records().isEmpty)
        #expect(rig.reports.values.isEmpty)
        #expect(rig.lastHangs.values.isEmpty)
    }

    /// With the feature off the runtime source gets no sink, so the shim installs no dump handler.
    @Test func theFeatureOffGivesNoSink() {
        let rig = Rig()
        #expect(WatchdogReporting.chromiumHangSink(enabled: false, post: rig.lane.post, record: { _, _ in }) == nil)
    }
}

/// A never-started watchdog whose thread-hang sinks are the app's (``WatchdogReporting/threadHangSink(report:collector:)``)
/// with a recording crash reporter and a real, enabled collector that keeps thread hangs, and a lane run by hand.
private struct Rig {
    let watchdog = MainThreadWatchdog()
    let reports = Recorded<ThreadHangEvent>()
    let lastHangs = Recorded<LastHangCause>()
    let collector = HangReportCollector(resolve: { _ in [] }, keepsThreadHangs: true, schedule: { $0() })
    let lane = ManualLane()

    init() {
        collector.setEnabled(true)
        let (reports, lastHangs) = (reports, lastHangs)
        watchdog.onThreadHang = WatchdogReporting.threadHangSink(report: { reports.append($0) }, collector: collector)
        watchdog.onLastHang = { lastHangs.append($0) }
    }
}

/// A lane whose jobs run only when the test says.
private nonisolated final class ManualLane: Sendable {
    private let jobs = Mutex<[@Sendable () -> Void]>([])
    var pending: Int { jobs.withLock { $0.count } }
    var post: @Sendable (@escaping @Sendable () -> Void) -> Void { { [self] job in jobs.withLock { $0.append(job) } } }
    func runAll() {
        let taken = jobs.withLock { jobs in
            let taken = jobs
            jobs.removeAll()
            return taken
        }
        for job in taken { job() }
    }
}

/// Values appended from any thread and read by the test.
private nonisolated final class Recorded<Value: Sendable>: Sendable {
    private let state = Mutex<[Value]>([])
    var values: [Value] { state.withLock { $0 } }
    func append(_ value: Value) { state.withLock { $0.append(value) } }
}
