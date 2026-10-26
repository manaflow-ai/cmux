@testable import CmuxNextControl
import CmuxNextCompat
import CmuxNextSettings
import Darwin
import Foundation
import Testing

/// ``ThreadHangWatcher``: hang-watch scopes on per-thread atomic slots (p02-threads-016, Chrome's
/// base/threading/hang_watcher.cc). The scopes run on named threads that spin, so the watcher
/// samples a thread that is running its work, as a real hang does.
@Suite(.serialized, .timeLimit(.minutes(1))) struct HangWatchScopeTests {
    @Test func aScopePastItsDeadlineIsReportedOnceNamingTheThread() async throws {
        let watcher = ThreadHangWatcher(log: HangLog(capacity: 16))
        let reports = Reports()
        watcher.start(onHang: { reports.add($0) })
        defer { watcher.stop() }
        await onThread(named: "hang-watch-test") {
            let token = watcher.enter("test.overrun", deadline: .milliseconds(100))
            let began = uptime()
            // 150 ms of work, then on until the watcher sampled it (2 s at most): a hang lasts until it ends.
            spin { uptime() - began >= 150_000_000 && (reports.count > 0 || uptime() - began >= 2_000_000_000) }
            watcher.leave(token)
        }
        let all = reports.all
        #expect(all.count == 1, "one report per scope, however long it overruns")
        let report = try #require(all.first)
        #expect(report.thread == "hang-watch-test")
        #expect(report.scope == "test.overrun")
        #expect(report.elapsed >= .milliseconds(100))
        #expect(abs((report.timeout - .milliseconds(100)) / .milliseconds(1)) < 1, "\(report.timeout)")
        #expect(!report.addresses.isEmpty, "the hung thread's stack")
        let record = try #require(watcher.log.records().last)
        #expect(record.kind == .hang)
        #expect(record.details["thread"] == JSONValue.string("hang-watch-test"))
        #expect(record.details["scope"] == JSONValue.string("test.overrun"))
        #expect(watcher.log.summary.count == 0, "not a main-thread stall")
    }

    @Test func aScopeThatEndsBeforeItsDeadlineIsNotReported() async throws {
        let watcher = ThreadHangWatcher(log: HangLog(capacity: 16))
        let reports = Reports()
        watcher.start(onHang: { reports.add($0) })
        defer { watcher.stop() }
        await onThread(named: "hang-watch-short") {
            let token = watcher.enter("test.short", deadline: .milliseconds(100))
            let began = uptime()
            spin { uptime() - began >= 50_000_000 }
            watcher.leave(token)
        }
        let value = watcher.watching("test.closure", deadline: .seconds(1)) { 42 }
        #expect(value == 42)
        // Past the scope's deadline: the time is the scenario under test, not a wait for a condition.
        try await Task.sleep(for: .milliseconds(150))
        #expect(reports.count == 0)
        #expect(watcher.log.records().isEmpty)
    }

    /// Chrome keeps the inner scope's deadline until it ends, then the outer one applies again: an
    /// outer scope already past its deadline is reported as soon as the inner one leaves.
    @Test func leavingANestedScopeRestoresTheOuterDeadline() async throws {
        let watcher = ThreadHangWatcher(log: HangLog(capacity: 16))
        let reports = Reports()
        watcher.start(onHang: { reports.add($0) })
        defer { watcher.stop() }
        let reportedDuringInner = Atomic<Int>(-1)
        await onThread(named: "hang-watch-nested") {
            let outer = watcher.enter("test.outer", deadline: .milliseconds(100))
            let inner = watcher.enter("test.inner", deadline: .seconds(10))
            let began = uptime()
            spin { uptime() - began >= 150_000_000 }
            reportedDuringInner.store(reports.count, ordering: .relaxed)
            watcher.leave(inner)
            spin { reports.count > 0 || uptime() - began >= 2_000_000_000 }
            watcher.leave(outer)
        }
        #expect(reportedDuringInner.load(ordering: .relaxed) == 0, "the inner deadline is 10 s away")
        #expect(reports.all.map(\.scope) == ["test.outer"])
    }

    @Test func aThreadPastTheSlotTableIsCountedAndNotWatched() async throws {
        let watcher = ThreadHangWatcher(log: HangLog(capacity: 16), capacity: 1)
        let second = Mutex<HangWatchToken?>(nil)
        let first = Mutex<HangWatchToken?>(nil)
        await onThread(named: "hang-watch-first") {
            let token = watcher.enter("test.first", deadline: .seconds(1))
            first.withLock { $0 = token }
            let done = Atomic<Bool>(false)
            // The first thread keeps its slot while the second asks for one.
            Thread {
                second.withLock { $0 = watcher.enter("test.second", deadline: .seconds(1)) }
                done.store(true, ordering: .releasing)
            }.start()
            spin { done.load(ordering: .acquiring) }
            watcher.leave(token)
        }
        #expect(first.withLock { $0?.slot } != 0)
        #expect(second.withLock { $0 } == HangWatchToken.unwatched)
        #expect(watcher.slotOverflows == 1)
    }

    #if DEBUG
    /// An idle process has no watcher wakeup: with no scope the thread parks with no timer.
    @Test func anIdleWatcherNeverWakes() async throws {
        let watcher = ThreadHangWatcher(log: HangLog(capacity: 16))
        watcher.start()
        defer { watcher.stop() }
        // Five idle seconds are the scenario under test.
        try await Task.sleep(for: .seconds(5))
        #expect(watcher.watcherWakes.load(ordering: .relaxed) == 0)
        #expect(watcher.isParked)
    }

    /// After the last scope the watcher lingers one period, then parks again with no timer.
    @Test func theWatcherParksAgainAfterTheLastScope() async throws {
        let watcher = ThreadHangWatcher(log: HangLog(capacity: 16))
        watcher.start()
        defer { watcher.stop() }
        await onThread(named: "hang-watch-once") {
            watcher.leave(watcher.enter("test.once", deadline: .milliseconds(100)))
        }
        // Past the linger period, then one idle second: the times are the scenario.
        try await Task.sleep(for: .milliseconds(500))
        let settled = watcher.watcherWakes.load(ordering: .relaxed)
        try await Task.sleep(for: .seconds(1))
        #expect(settled <= 3, "\(settled) wakes for one scope")
        #expect(watcher.watcherWakes.load(ordering: .relaxed) == settled)
        #expect(watcher.isParked)
        #expect(watcher.wakeRequests == 1, "only the first scope after the park wakes the watcher")
    }
    #endif

    /// Enter plus leave is a clock read and atomic stores: under 50 ns at p99 (per pair, over
    /// batches of 256), and the scopes signal the watcher at most twice in the whole
    /// run. Optimized builds only, as the trace ring's cost tests; elsewhere it shows as skipped.
    @Test(.enabled(if: !_isDebugAssertConfiguration(), "needs an optimized build (-c release)"))
    func enterAndLeaveCostUnderFiftyNanoseconds() async throws {
        let watcher = ThreadHangWatcher(log: HangLog(capacity: 16))
        watcher.start()
        defer { watcher.stop() }
        let p99 = Mutex<Double>(0)
        await onThread(named: "hang-watch-cost") {
            let batches = 2_000
            let pairs = 256
            watcher.leave(watcher.enter("test.cost", deadline: .milliseconds(100))) // claims the slot
            var perPair: [Double] = []
            perPair.reserveCapacity(batches)
            for _ in 0..<batches {
                let start = uptime()
                for _ in 0..<pairs {
                    watcher.leave(watcher.enter("test.cost", deadline: .milliseconds(100)))
                }
                perPair.append(Double(uptime() - start) / Double(pairs))
            }
            perPair.sort()
            p99.withLock { $0 = perPair[batches * 99 / 100] }
        }
        let cost = p99.withLock { $0 }
        print("hang watch enter+leave p99: \(cost) ns")
        #expect(cost < 50, "\(cost) ns per enter+leave at p99")
        #expect(watcher.wakeRequests <= 2, "\(watcher.wakeRequests) watcher wakes")
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

/// The reports the watcher delivered, on its thread.
private final class Reports: Sendable {
    private let list = Mutex<[ThreadHangWatcher.Report]>([])
    private let delivered = Atomic<Int>(0)

    func add(_ report: ThreadHangWatcher.Report) {
        list.withLock { $0.append(report) }
        delivered.add(1, ordering: .releasing)
    }

    var count: Int { delivered.load(ordering: .acquiring) }
    var all: [ThreadHangWatcher.Report] { list.withLock { $0 } }
}
