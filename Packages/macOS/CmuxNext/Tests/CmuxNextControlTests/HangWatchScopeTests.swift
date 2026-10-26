@testable import CmuxNextControl
import CmuxNextCompat
import CmuxNextSettings
import CmuxNextTrace
import Darwin
import Foundation
import Testing

/// Hang-watch scopes on other threads, scanned on the main-thread watchdog's thread (p02-threads-016,
/// Chrome's base/threading/hang_watcher.cc): the watchdog thread runs as at launch with the main run loop
/// asleep, and the scopes run on named threads that spin, so the monitor samples a thread that is running
/// its work, as a real hang does.
@Suite(.serialized, .timeLimit(.minutes(1))) struct HangWatchScopeTests {
    /// A thread blocked inside its scope (p10-stability-031): one jank with no stack at the budget, then one
    /// hang dump whose stack has the blocked function on top (under the `read` it waits in), with the crash
    /// keys of the moment, and the hung thread in the crash-key page.
    @Test func aBlockedScopeJanksOnceThenDumpsOneHangWithTheBlockedFunctionOnTop() async throws {
        let crashKeys = RecordingCrashKeys()
        crashKeys.setCrashKey(.actionIndex, 42)
        let (watchdog, watch) = Self.running(hangAfterBudget: .milliseconds(300), crashKeys: crashKeys)
        defer { watchdog.stop() }
        var fds: [Int32] = [0, 0]
        try #require(pipe(&fds) == 0)
        defer { close(fds[0]); close(fds[1]) }
        let readEnd = fds[0]
        let port = PortBox()
        let blocked = Task.detached {
            await onThread(named: "hang-watch-blocked") {
                port.value.store(pthread_mach_thread_np(pthread_self()), ordering: .releasing)
                let thread = watch.registerThread(.io, name: "test.blocked")
                watch.watch(thread, deadline: .milliseconds(100)) { _ = cmux_hang_watch_test_blocked_in_read(readEnd) }
                watch.unregister(thread)
            }
        }
        // The blocked thread stays in its scope until the monitor dumped it (5 s at most); the time is the scenario.
        let began = uptime()
        while watchdog.threadHangs.summary.count == 0, uptime() - began < 5_000_000_000 {
            try await Task.sleep(for: .milliseconds(20))
        }
        var byte: UInt8 = 1
        _ = write(fds[1], &byte, 1)
        await blocked.value
        let records = watchdog.threadHangs.records()
        #expect(records.map(\.kind) == [.jank, .hang], "each tier once, however long it blocks")
        let jank = try #require(records.first)
        #expect(jank.addresses.isEmpty, "a jank samples no stack")
        #expect(jank.details["thread"] == JSONValue.string("hang-watch-blocked"))
        let hang = try #require(records.last)
        #expect(hang.details["scope"] == JSONValue.string("test.blocked"))
        #expect(hang.details["thread"] == JSONValue.string("hang-watch-blocked"))
        let symbols = StackSymbolicator(map: nil).frames(for: hang.addresses).prefix(3).compactMap(\.symbol)
        #expect(symbols.contains { $0.contains("cmux_hang_watch_test_blocked_in_read") }, "top frames: \(symbols)")
        #expect(hang.details["crash_keys"]?.objectValue?["action_index"] == JSONValue(42))
        #expect(crashKeys.crashKey(.lastThreadHangPort) == UInt64(port.value.load(ordering: .acquiring)))
        #expect(crashKeys.crashKey(.lastThreadHangUptime) == jank.startUptimeNanos, "the budget's end")
        #expect(watchdog.threadHangs.summary.jankCount == 1)
        #expect(watchdog.log.records().isEmpty, "not a main-thread stall")
    }

    @Test func theCEFPumpCrashKeyNamesTheMainThreadPhase() {
        #expect(MainThreadWatchdog.phaseLabel(inCEFPump: 1) == "cef_pump")
        #expect(MainThreadWatchdog.phaseLabel(inCEFPump: 0) == nil)
    }

    @Test func aScopeThatEndsBeforeItsDeadlineIsNotReported() async throws {
        let (watchdog, watch) = Self.running()
        defer { watchdog.stop() }
        await onThread(named: "hang-watch-short") {
            let thread = watch.registerThread(.io, name: "test.short")
            let scope = watch.watch(thread, deadline: .milliseconds(100))
            let began = uptime()
            spin { uptime() - began >= 50_000_000 }
            scope.close()
            watch.unregister(thread)
        }
        // Past the scope's deadline and one scan period: the time is the scenario under test.
        try await Task.sleep(for: .milliseconds(250))
        #expect(watchdog.threadHangs.records().isEmpty)
    }

    /// An outer scope reported, then an inner one: when the inner one closes, the outer one is not
    /// reported a second time (its reported flag comes back with it).
    @Test func aNestedScopeDoesNotReportItsOuterScopeAgain() async throws {
        let (watchdog, watch) = Self.running(hangAfterBudget: .milliseconds(200))
        defer { watchdog.stop() }
        await onThread(named: "hang-watch-nested") {
            let thread = watch.registerThread(.io, name: "test.nested")
            let began = uptime()
            let outer = watch.watch(thread, deadline: .milliseconds(100))
            spin { watchdog.threadHangs.summary.count >= 1 || uptime() - began >= 2_000_000_000 }
            let inner = watch.watch(thread, deadline: .milliseconds(100))
            spin { watchdog.threadHangs.summary.count >= 2 || uptime() - began >= 4_000_000_000 }
            inner.close()
            let closed = uptime()
            spin { uptime() - closed >= 500_000_000 }
            outer.close()
            watch.unregister(thread)
        }
        #expect(watchdog.threadHangs.summary.count == 2, "one hang dump per scope")
        #expect(watchdog.threadHangs.summary.jankCount == 2, "one jank per scope")
    }

    #if DEBUG
    /// An idle process has no hang-watch wakeup: with no scope the watchdog thread waits with no limit.
    @Test func anIdleMonitorNeverWakesTheWatchdogThread() async throws {
        let (watchdog, _) = Self.running()
        defer { watchdog.stop() }
        try await Task.sleep(for: .milliseconds(200)) // the attach's own wake
        let before = watchdog.watchdogWakes.load(ordering: .relaxed)
        // Five idle seconds are the scenario under test.
        try await Task.sleep(for: .seconds(5))
        #expect(watchdog.watchdogWakes.load(ordering: .relaxed) == before)
    }

    /// One 5 s scope open for 2 s: the open wakes the watchdog thread once, and nothing wakes it again
    /// before the deadline (no periodic scan while nothing changes).
    @Test func aLongScopeCostsOneWake() async throws {
        let (watchdog, watch) = Self.running()
        defer { watchdog.stop() }
        let lane = watch.registerLane("test.job")
        try await Task.sleep(for: .milliseconds(200))
        let before = watchdog.watchdogWakes.load(ordering: .relaxed)
        let scope = watch.watch(lane, deadline: .seconds(5))
        // Two seconds of the job are the scenario under test.
        try await Task.sleep(for: .seconds(2))
        scope.close()
        let wakes = watchdog.watchdogWakes.load(ordering: .relaxed) - before
        #expect(wakes <= 2, "\(wakes) watchdog wakes for one 5 s scope open 2 s")
        #expect(watch.wakeRequests == 1)
    }

    /// A thread that opens short scopes back to back (16 ms deadlines, 0.2 ms of work each) for a second:
    /// the monitor scans about once per minimum deadline (100 ms), never once per scope.
    @Test func shortScopesBackToBackDoNotWakeTheWatchdogPerScope() async throws {
        let (watchdog, watch) = Self.running()
        defer { watchdog.stop() }
        try await Task.sleep(for: .milliseconds(200))
        let before = watchdog.watchdogWakes.load(ordering: .relaxed)
        let opened = Atomic<Int>(0)
        await onThread(named: "hang-watch-feed") {
            let lane = watch.registerLane("test.feed")
            let began = uptime()
            while uptime() - began < 1_000_000_000 {
                let scope = watch.watch(lane, deadline: .milliseconds(16))
                let start = uptime()
                spin { uptime() - start >= 200_000 }
                scope.close()
                opened.add(1, ordering: .relaxed)
            }
            watch.unregister(lane)
        }
        let wakes = watchdog.watchdogWakes.load(ordering: .relaxed) - before
        #expect(opened.load(ordering: .relaxed) > 1_000)
        #expect(wakes <= 30, "\(wakes) watchdog wakes for \(opened.load(ordering: .relaxed)) scopes in 1 s")
    }
    #endif

    /// The watchdog runs once: a start after a stop starts no second thread.
    @MainActor
    @Test func aStoppedWatchdogDoesNotStartAgain() {
        let watchdog = MainThreadWatchdog(configuration: .init(threshold: .milliseconds(50), sampleStacks: false, logStalls: false))
        watchdog.start()
        #expect(watchdog.isRunning)
        watchdog.stop()
        watchdog.start()
        #expect(!watchdog.isRunning)
    }

    /// A watchdog whose thread runs as at launch (main run loop asleep) and watches a fresh slot table.
    private static func running(hangAfterBudget: Duration = .seconds(2),
                                crashKeys: (any CrashKeyStore)? = nil) -> (MainThreadWatchdog, HangWatch) {
        let watchdog = MainThreadWatchdog(configuration: .init(threshold: .milliseconds(50), sampleStacks: false, logStalls: false))
        let watch = HangWatch(hangAfterBudget: hangAfterBudget)
        watchdog.attach(hangWatch: watch, crashKeys: crashKeys)
        watchdog.running.store(true, ordering: .releasing)
        let thread = Thread { watchdog.watch(sampler: nil) }
        thread.name = "hang-watch-test-watchdog"
        thread.start()
        return (watchdog, watch)
    }
}

private func uptime() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

/// The blocked function of the hang-dump test: it waits in `read(2)` until the test writes a byte. A C
/// name, exported from the test bundle, so `dladdr` names the frame.
@_cdecl("cmux_hang_watch_test_blocked_in_read")
@inline(never)
public func cmux_hang_watch_test_blocked_in_read(_ fd: Int32) -> Int {
    var byte: UInt8 = 0
    let count = read(fd, &byte, 1)
    return count + Int(byte) // used after the read, so the read is no tail call
}

/// The blocked thread's Mach port, set on that thread.
private final class PortBox: Sendable {
    let value = Atomic<UInt32>(0)
}

/// A crash-key page in memory (``CrashKeyStore``): what the hang monitor read and wrote.
private final class RecordingCrashKeys: CrashKeyStore {
    private let values = Mutex<[CrashKeySlot: UInt64]>([:])
    func setCrashKey(_ slot: CrashKeySlot, _ value: UInt64) { values.withLock { $0[slot] = value } }
    func crashKey(_ slot: CrashKeySlot) -> UInt64 { values.withLock { $0[slot] ?? 0 } }
}

/// Runs the scope's work on the calling thread until `done` holds.
private func spin(until done: () -> Bool) {
    while !done() {}
}

/// Runs `body` on a new thread with the kernel name `name` and returns when it has finished.
private func onThread(named name: String, _ body: @escaping @Sendable () -> Void) async {
    await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
        let thread = Thread {
            pthread_setname_np(name)
            body()
            finished.resume()
        }
        thread.qualityOfService = .userInitiated
        thread.start()
    }
}
