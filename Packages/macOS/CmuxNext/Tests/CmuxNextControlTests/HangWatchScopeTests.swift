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
    @Test func aScopePastItsDeadlineIsReportedOnceNamingTheThread() async throws {
        let (watchdog, watch) = Self.running()
        defer { watchdog.stop() }
        await onThread(named: "hang-watch-test") {
            let thread = watch.registerThread(.io, name: "test.overrun")
            let scope = watch.watch(thread, deadline: .milliseconds(100))
            let began = uptime()
            // 150 ms of work, then on until the monitor sampled it (2 s at most): a hang lasts until it ends.
            spin { uptime() - began >= 150_000_000 && (watchdog.threadHangs.summary.count > 0 || uptime() - began >= 2_000_000_000) }
            scope.close()
            watch.unregister(thread)
        }
        let records = watchdog.threadHangs.records()
        #expect(records.count == 1, "one report per scope, however long it overruns")
        let record = try #require(records.first)
        #expect(record.kind == .hang)
        #expect(record.details["thread"] == JSONValue.string("hang-watch-test"))
        #expect(record.details["scope"] == JSONValue.string("test.overrun"))
        #expect(!record.addresses.isEmpty, "the hung thread's stack")
        #expect(watchdog.log.records().isEmpty, "not a main-thread stall")
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
        let (watchdog, watch) = Self.running()
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
            spin { uptime() - closed >= 300_000_000 }
            outer.close()
            watch.unregister(thread)
        }
        #expect(watchdog.threadHangs.summary.count == 2)
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
    private static func running() -> (MainThreadWatchdog, HangWatch) {
        let watchdog = MainThreadWatchdog(configuration: .init(threshold: .milliseconds(50), sampleStacks: false, logStalls: false))
        let watch = HangWatch()
        watchdog.attach(hangWatch: watch)
        watchdog.running.store(true, ordering: .releasing)
        let thread = Thread { watchdog.watch(sampler: nil) }
        thread.name = "hang-watch-test-watchdog"
        thread.start()
        return (watchdog, watch)
    }
}

private func uptime() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

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
