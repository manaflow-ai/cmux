@testable import CmuxNextControl
import CmuxNextCompat
import CmuxNextSignposts
@testable import CmuxNextTrace
import Darwin
import Foundation
import Testing

/// A watched thread's hang goes out (Chrome's `HangWatcher::RecordHang` in
/// base/threading/hang_watcher.cc): the monitor samples the hung thread by its Mach port, writes a
/// `hang.thread_hung` instant into the ring and hands one ``ThreadHang`` with the registration's name and the
/// thread's frames to ``MainThreadWatchdog/onThreadHang`` and the last-hang trigger
/// (``MainThreadWatchdog/onLastHang``), at most once per registration name per report interval. The threads block in `read(2)` inside their scope; each hang dump writes the byte that frees them,
/// so the tests wait on the monitor's reports, not on a clock.
@Suite(.serialized, .timeLimit(.minutes(1))) struct ThreadHangReportTests {
    #if DEBUG
    @Test func aBlockedRegisteredThreadGivesOneReportWithItsNameAndFramesAndOneRingInstant() async throws {
        let pipe = try BlockingPipe()
        defer { pipe.close() }
        let fixture = Fixture(interval: .seconds(300), unblock: pipe)
        defer { fixture.watchdog.stop() }
        let tid = Recorded<UInt64>()
        await onThread(named: "thread-hang-blocked") {
            var id: UInt64 = 0
            pthread_threadid_np(nil, &id)
            tid.append(id)
            let thread = fixture.watch.registerThread(.io, name: "test.thread-hang")
            fixture.watch.watch(thread, deadline: .milliseconds(100)) { _ = cmux_thread_hang_test_blocked_in_read(pipe.readEnd) }
            fixture.watch.unregister(thread)
        }
        let delivered = fixture.deliveries.values
        #expect(delivered.count == 1, "one report for one hang")
        let hang = try #require(delivered.first)
        #expect(hang.name == "test.thread-hang")
        #expect(hang.kind == .io)
        #expect(hang.kindName == "io")
        #expect(hang.threadName == "thread-hang-blocked")
        #expect(hang.overrun >= .milliseconds(300), "a hang is reported only past the hang tier")
        let symbols = StackSymbolicator(map: nil).frames(for: hang.addresses).prefix(3).compactMap(\.symbol)
        #expect(symbols.contains { $0.contains("cmux_thread_hang_test_blocked_in_read") }, "top frames: \(symbols)")
        let instants = fixture.ring.values.filter { $0.name == SignpostName.hangThreadHung.rawValue }
        #expect(instants.count == 1)
        let instant = try #require(instants.first)
        #expect(instant.phase == .instant)
        #expect(instant.categoryBit == SignpostName.hangThreadHung.traceCategory.traceBit)
        #expect([instant.arg0] == tid.values, "arg0 is the hung thread's id")
        #expect(instant.arg1 >= 300, "arg1 is how far past the budget, in ms")
        #expect(fixture.lastHangs.values == [.threadHang(hang)], "one thread hang starts one last-hang bundle")
    }

    /// The last-hang bundle is local: it starts with no report sink (hang reports and crash reporting off).
    @Test func aThreadHangStartsTheLastHangBundleWithNoReportSink() async throws {
        let pipe = try BlockingPipe()
        defer { pipe.close() }
        let fixture = Fixture(interval: .seconds(300), unblock: pipe, reports: false)
        defer { fixture.watchdog.stop() }
        await onThread(named: "thread-hang-local") {
            let thread = fixture.watch.registerThread(.io, name: "test.local")
            fixture.watch.watch(thread, deadline: .milliseconds(100)) { _ = cmux_thread_hang_test_blocked_in_read(pipe.readEnd) }
            fixture.watch.unregister(thread)
        }
        #expect(fixture.deliveries.values.isEmpty)
        let causes = fixture.lastHangs.values
        #expect(causes.count == 1)
        guard case .threadHang(let hang)? = causes.first else { Issue.record("no thread hang: \(causes)"); return }
        #expect(hang.name == "test.local")
    }

    /// A registration that hangs twice within the interval is reported once (both hangs stay in the local log and
    /// the ring); another registration's hang in the same interval is still reported.
    @Test func aSecondHangOfOneRegistrationWithinTheIntervalIsNotReportedAgain() async throws {
        let pipe = try BlockingPipe()
        defer { pipe.close() }
        let fixture = Fixture(interval: .seconds(300), unblock: pipe)
        defer { fixture.watchdog.stop() }
        await onThread(named: "thread-hang-twice") {
            let thread = fixture.watch.registerThread(.io, name: "test.twice")
            for _ in 0..<2 {
                fixture.watch.watch(thread, deadline: .milliseconds(100)) { _ = cmux_thread_hang_test_blocked_in_read(pipe.readEnd) }
            }
            fixture.watch.unregister(thread)
            let other = fixture.watch.registerLane("test.other")
            fixture.watch.watch(other, deadline: .milliseconds(100)) { _ = cmux_thread_hang_test_blocked_in_read(pipe.readEnd) }
            fixture.watch.unregister(other)
        }
        #expect(fixture.watchdog.threadHangs.records().count == 3, "every hang dump stays in debug.hangs")
        #expect(fixture.ring.values.filter { $0.name == SignpostName.hangThreadHung.rawValue }.count == 3)
        #expect(fixture.deliveries.values.map(\.name) == ["test.twice", "test.other"])
        #expect(fixture.deliveries.values.last?.kind == .lane)
        #expect(fixture.lastHangs.values == fixture.deliveries.values.map { .threadHang($0) }, "the bundle's trigger is rate-limited alike")
    }

    /// The limit is the interval, not once per launch: with no interval each hang goes out.
    @Test func eachHangIsReportedOnceTheIntervalHasPassed() async throws {
        let pipe = try BlockingPipe()
        defer { pipe.close() }
        let fixture = Fixture(interval: .zero, unblock: pipe)
        defer { fixture.watchdog.stop() }
        await onThread(named: "thread-hang-again") {
            let thread = fixture.watch.registerThread(.io, name: "test.again")
            for _ in 0..<2 {
                fixture.watch.watch(thread, deadline: .milliseconds(100)) { _ = cmux_thread_hang_test_blocked_in_read(pipe.readEnd) }
            }
            fixture.watch.unregister(thread)
        }
        #expect(fixture.deliveries.values.map(\.name) == ["test.again", "test.again"])
    }
    #endif

    /// A scope that ends before its hang tier is a jank only: nothing goes out and the ring has no instant.
    @Test func aJankIsNotReported() async throws {
        let fixture = Fixture(interval: .seconds(300), unblock: nil)
        defer { fixture.watchdog.stop() }
        await onThread(named: "thread-hang-jank") {
            let thread = fixture.watch.registerThread(.io, name: "test.jank")
            let scope = fixture.watch.watch(thread, deadline: .milliseconds(100))
            let began = uptime()
            while fixture.watchdog.threadJanks.summary.count == 0, uptime() - began < 2_000_000_000 {}
            scope.close()
            fixture.watch.unregister(thread)
        }
        #expect(fixture.watchdog.threadJanks.summary.count == 1)
        #expect(fixture.deliveries.values.isEmpty)
        #expect(fixture.lastHangs.values.isEmpty)
        #expect(fixture.ring.values.isEmpty)
    }
}

/// A running watchdog (its thread as at launch, the main run loop asleep) that watches a fresh slot table with a
/// 300 ms hang tier, records each delivered ``ThreadHang`` (with no report sink when `reports` is false), each
/// last-hang cause and each ring record, and, after each hang dump, writes the byte that frees the blocked thread.
private struct Fixture {
    let watchdog: MainThreadWatchdog
    let watch: HangWatch
    let deliveries = Recorded<ThreadHang>()
    let lastHangs = Recorded<LastHangCause>()
    let ring = Recorded<TraceRuntime.StubRecord>()

    init(interval: Duration, unblock: BlockingPipe?, reports: Bool = true) {
        watchdog = MainThreadWatchdog(configuration: .init(threshold: .milliseconds(50), sampleStacks: false, logStalls: false,
                                                           hangReportInterval: interval))
        watch = HangWatch(hangAfterBudget: .milliseconds(300))
        let ring = ring
        let runtime = TraceRuntime(role: .app, clock: TraceClock(), stubRecorder: { ring.append($0) })
        runtime.setCategoryMask(UInt64(1) << UInt64(SignpostName.hangThreadHung.traceCategory.traceBit))
        let (deliveries, lastHangs) = (deliveries, lastHangs)
        if reports { watchdog.onThreadHang = { deliveries.append($0) } }
        watchdog.onLastHang = { lastHangs.append($0) }
        var source = HangMonitor.Source(watch: watch, crashKeys: nil, trace: runtime)
        #if DEBUG
        source.afterHangForTesting = { _ in unblock?.release() }
        #endif
        watchdog.attach(source)
        watchdog.running.store(true, ordering: .releasing)
        let thread = Thread { [watchdog] in watchdog.watch(sampler: nil) }
        thread.name = "thread-hang-test-watchdog"
        thread.qualityOfService = .userInitiated
        thread.start()
    }
}

/// Values appended from the watchdog thread and read by the test.
private final class Recorded<Value: Sendable>: Sendable {
    private let state = Mutex<[Value]>([])
    var values: [Value] { state.withLock { $0 } }
    func append(_ value: Value) { state.withLock { $0.append(value) } }
}

/// A pipe a scope's thread blocks reading; ``release()`` writes one byte, which frees one read.
private final class BlockingPipe: Sendable {
    let readEnd: Int32
    let writeEnd: Int32

    init() throws {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw POSIXError(.EMFILE) }
        (readEnd, writeEnd) = (fds[0], fds[1])
    }

    func release() {
        var byte: UInt8 = 1
        _ = write(writeEnd, &byte, 1)
    }

    func close() {
        Darwin.close(readEnd)
        Darwin.close(writeEnd)
    }
}

private func uptime() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

/// The blocked function: it waits in `read(2)` until the hang dump writes a byte. A C name, exported from the test
/// bundle, so `dladdr` names the frame.
@_cdecl("cmux_thread_hang_test_blocked_in_read")
@inline(never)
public func cmux_thread_hang_test_blocked_in_read(_ fd: Int32) -> Int {
    var byte: UInt8 = 0
    let count = read(fd, &byte, 1)
    return count + Int(byte) // used after the read, so the read is no tail call
}

/// Runs `body` on a new thread with the kernel name `name` and returns when it has finished.
private func onThread(named name: String, _ body: @escaping @Sendable () -> Void) async {
    await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
        let thread = Thread {
            pthread_setname_np(name)
            body()
            finished.resume()
        }
        thread.name = name
        thread.qualityOfService = .userInitiated
        thread.start()
    }
}
