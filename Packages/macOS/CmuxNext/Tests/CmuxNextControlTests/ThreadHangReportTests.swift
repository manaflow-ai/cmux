@testable import CmuxNextControl
@testable import CmuxNextTrace
import CmuxNextCompat
import Darwin
import Foundation
import Testing

/// A registered thread blocked past its hang-watch deadline gives one report with its name and its
/// own frames, and the same hang never reports twice (task p09-observability-068; Chrome's
/// `HangWatcher::Monitor()` and `deadline_ignore_threshold_`, base/threading/hang_watcher.cc).
@Suite(.serialized, .timeLimit(.minutes(1))) struct ThreadHangReportTests {
    private static let second: UInt64 = 1_000_000_000

    @Test func aBlockedRegisteredThreadGivesOneEventWithItsNameAndFrames() throws {
        let fixture = Fixture()
        let blocked = try ThreadHangTestBlockedThread.start(name: "terminal-output")
        defer { blocked.finish() }
        fixture.clock.nanos.store(10 * Self.second + 1_500_000_000, ordering: .relaxed)
        let overdue = Fixture.overdue(slot: 3, kind: .lane, port: blocked.port, deadlineNanos: 10 * Self.second)
        #expect(fixture.reporter.capture(overdue))
        // The monitor sees the same open scope at its next checks: no second event.
        #expect(!fixture.reporter.capture(overdue))
        #expect(!fixture.reporter.capture(overdue))
        let hangs = fixture.hangs.withLock { $0 }
        try #require(hangs.count == 1, "one blocked scope gave \(hangs.count) events")
        let hang = try #require(hangs.first)
        #expect(hang.name == "terminal-output")
        #expect(hang.kind == .lane)
        #expect(hang.overdue == .milliseconds(1_500))
        #expect(hang.addresses.count >= 3, "frames: \(hang.addresses.count)")
        let frames = StackSymbolicator().frames(for: hang.addresses)
        #expect(frames.contains { $0.symbol?.contains("blockRegisteredThreadForTest") == true },
                "the sample is not the hung thread's stack: \(frames.prefix(8).map(\.description))")
        #expect(fixture.bundles.withLock { $0 } == 1, "the last-hang bundle was not asked for once")
        #expect(fixture.trace.stubRecordCount.load(ordering: .relaxed) == 1, "one hang.thread_hung ring instant")
    }

    @Test func aNameReportsAtMostOncePerInterval() throws {
        let fixture = Fixture(interval: .seconds(300))
        let blocked = try ThreadHangTestBlockedThread.start(name: "daemon-reader")
        defer { blocked.finish() }
        fixture.clock.nanos.store(2 * Self.second, ordering: .relaxed)
        #expect(fixture.reporter.capture(Fixture.overdue(slot: 1, kind: .io, port: blocked.port, deadlineNanos: Self.second)))
        // A later scope of the same thread hangs again a minute on: its ring instant, no event.
        fixture.clock.nanos.store(62 * Self.second, ordering: .relaxed)
        #expect(!fixture.reporter.capture(Fixture.overdue(slot: 1, kind: .io, port: blocked.port, deadlineNanos: 61 * Self.second)))
        #expect(fixture.hangs.withLock { $0.count } == 1)
        // Past the interval it reports again.
        fixture.clock.nanos.store(303 * Self.second, ordering: .relaxed)
        #expect(fixture.reporter.capture(Fixture.overdue(slot: 1, kind: .io, port: blocked.port, deadlineNanos: 302 * Self.second)))
        #expect(fixture.hangs.withLock { $0.count } == 2)
        #expect(fixture.trace.stubRecordCount.load(ordering: .relaxed) == 3)
    }

    @Test func theMainSlotGetsOnlyItsRingInstant() {
        let fixture = Fixture()
        fixture.clock.nanos.store(5 * Self.second, ordering: .relaxed)
        let main = Fixture.overdue(slot: 0, kind: .main, port: pthread_mach_thread_np(pthread_self()), deadlineNanos: 3 * Self.second)
        #expect(!fixture.reporter.capture(main), "the main thread's hang is MainThreadWatchdog's report")
        #expect(fixture.hangs.withLock { $0.isEmpty })
        #expect(fixture.trace.stubRecordCount.load(ordering: .relaxed) == 1)
    }

    @Test func aThreadThatCannotBeSampledReportsNothing() {
        let fixture = Fixture()
        let calling = Fixture.overdue(slot: 1, kind: .pool, port: pthread_mach_thread_np(pthread_self()), deadlineNanos: 0)
        let null = Fixture.overdue(slot: 2, kind: .pool, port: thread_act_t(MACH_PORT_NULL), deadlineNanos: 0)
        #expect(!fixture.reporter.capture(calling), "the watchdog thread never suspends itself")
        #expect(!fixture.reporter.capture(null))
        #expect(fixture.hangs.withLock { $0.isEmpty })
        #expect(fixture.bundles.withLock { $0 } == 0)
    }

    @Test func theWatchdogForwardsOverdueSlotsOnlyOnceAttached() throws {
        let fixture = Fixture()
        let blocked = try ThreadHangTestBlockedThread.start(name: "control")
        defer { blocked.finish() }
        let watchdog = MainThreadWatchdog(configuration: .init(logStalls: false))
        let overdue = Fixture.overdue(slot: 4, kind: .control, port: blocked.port, deadlineNanos: 0)
        #expect(!watchdog.captureThreadHang(overdue), "no reporter attached: nothing is reported")
        watchdog.attach(threadHangs: fixture.reporter)
        #expect(watchdog.captureThreadHang(Fixture.overdue(slot: 4, kind: .control, port: blocked.port, deadlineNanos: 1)))
        #expect(fixture.hangs.withLock { $0.map(\.name) } == ["control"])
    }
}

/// A reporter on a hand-moved clock and its own trace runtime (every category on), with its sinks counted.
private struct Fixture {
    final class Clock: Sendable {
        let nanos = Atomic<UInt64>(0)
    }

    let clock: Clock
    let trace: TraceRuntime
    let hangs: SharedBox<[ThreadHangReporter.Hang]>
    let bundles: SharedBox<Int>
    let reporter: ThreadHangReporter

    init(interval: Duration = .seconds(300)) {
        let clock = Clock()
        let trace = TraceRuntime(role: .app)
        trace.setCategoryMask(.max)
        let hangs = SharedBox<[ThreadHangReporter.Hang]>([])
        let bundles = SharedBox<Int>(0)
        let reporter = ThreadHangReporter(configuration: .init(reportInterval: interval), trace: trace,
                                          uptime: { clock.nanos.load(ordering: .relaxed) })
        reporter.onHang = { hang in hangs.withLock { $0.append(hang) } }
        reporter.onLastHangBundle = { _ in bundles.withLock { $0 += 1 } }
        self.clock = clock
        self.trace = trace
        self.hangs = hangs
        self.bundles = bundles
        self.reporter = reporter
    }

    static func overdue(slot: UInt32, kind: HangWatch.ThreadKind, port: thread_act_t, deadlineNanos: UInt64) -> ThreadHangReporter.Overdue {
        let name: StaticString = switch kind {
        case .main: "main"
        case .io: "daemon-reader"
        case .lane: "terminal-output"
        case .control: "control"
        default: "background-work"
        }
        return ThreadHangReporter.Overdue(registration: HangWatch.Registration(slot: slot, generation: 1), kind: kind, name: name,
                                          nameID: UInt64(slot), port: port, deadlineNanos: deadlineNanos)
    }
}

/// A `Mutex` the test's sendable closures share.
private final class SharedBox<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>
    init(_ value: Value) { mutex = Mutex(value) }
    func withLock<R: Sendable>(_ body: (inout Value) -> R) -> R { mutex.withLock { body(&$0) } }
}

/// A thread busy in ``blockRegisteredThreadForTest(release:)`` until ``finish()``: a registered lane
/// job that never returns. Bounded at 20 s, so a failing test never leaves it running.
final class ThreadHangTestBlockedThread: Sendable {
    let release = Atomic<Bool>(false)
    private let started = Atomic<UInt32>(0)
    private let ended = Atomic<Bool>(false)

    var port: thread_act_t { started.load(ordering: .acquiring) }

    static func start(name: String) throws -> ThreadHangTestBlockedThread {
        let blocked = ThreadHangTestBlockedThread()
        let thread = Thread { [blocked] in
            blocked.started.store(pthread_mach_thread_np(pthread_self()), ordering: .releasing)
            blockRegisteredThreadForTest(release: blocked)
            blocked.ended.store(true, ordering: .releasing)
        }
        thread.name = name
        thread.start()
        let deadline = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + 5_000_000_000
        while blocked.port == 0, clock_gettime_nsec_np(CLOCK_UPTIME_RAW) < deadline {}
        try #require(blocked.port != 0, "the blocked thread never started")
        return blocked
    }

    func finish() {
        release.store(true, ordering: .releasing)
        let deadline = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + 5_000_000_000
        while !ended.load(ordering: .acquiring), clock_gettime_nsec_np(CLOCK_UPTIME_RAW) < deadline {}
    }
}

/// Busy until released (or 20 s): the hung thread's innermost frame, which its sample must name.
@inline(never)
func blockRegisteredThreadForTest(release blocked: ThreadHangTestBlockedThread) {
    let end = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + 20_000_000_000
    while !blocked.release.load(ordering: .acquiring), clock_gettime_nsec_np(CLOCK_UPTIME_RAW) < end {}
}
