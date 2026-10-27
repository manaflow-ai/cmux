import CmuxNextCompat
import Darwin
import Dispatch
import Foundation
import Testing
@testable import CmuxNextWakeups

/// The per-owner ledger's production paths (plans/cmux-next/chrome-parity/p06-scheduler.md, task
/// 009): the producer's background fold wake, a fold that runs while the main thread writes, the
/// write path's cost, and an off-main post's wait measured from the posting thread.
@MainActor @Suite(.timeLimit(.minutes(1))) struct MainOwnerLedgerTests {
    /// The producer wakes the fold once per quarter of the ring: 400 records through 8 slots, a
    /// main-actor turn per quarter, are all folded off main with none dropped and none left, and
    /// the snapshot itself folds nothing.
    @Test func theBackgroundFoldKeepsUpAQuarterAtATime() async {
        let folds = DispatchQueue(label: "MainOwnerLedgerTests.fold")
        let ledger = MainOwnerLedger(capacity: 8, folding: .queue(folds))
        let written = 400
        for index in 0..<written {
            ledger.ended(.visible, owner: 1, post: nil, startNanos: 0, runNanos: 1_000)
            // A quarter is written: the fold it woke runs before the next quarter.
            if (index + 1) % 2 == 0 { await Self.drain(folds) }
        }
        let snapshot = ledger.snapshot { _ in "rows" }
        #expect(snapshot.recorded == UInt64(written), "the background folds recorded every write")
        #expect(snapshot.dropped == 0)
        #expect(snapshot.pending == 0)
        #expect(snapshot.owners.first?.tasks == written)
    }

    /// A fold racing the producer (the app's utility queue and a snapshot on another thread) never
    /// loses or double-counts a record: each snapshot's `recorded + pending + dropped` grows and
    /// stays within what was written, and once quiet it is exactly what was written.
    @Test func aSnapshotDuringAConcurrentFoldCountsEveryRecordOnce() async {
        let ledger = MainOwnerLedger(capacity: 64, folding: .background)
        let written = 20_000
        let flags = LedgerRace()
        let reader = Task.detached { () -> Bool in
            var last: UInt64 = 0
            var consistent = true
            while !flags.stop.load(ordering: .acquiring) {
                ledger.fold()
                let snapshot = ledger.snapshot { _ in "storm" }
                let total = snapshot.recorded + UInt64(snapshot.pending) + snapshot.dropped
                // The producer counts a record after writing it: at most one is written and not counted.
                if total < last || total > UInt64(flags.written.load(ordering: .acquiring)) + 1 { consistent = false }
                last = total
            }
            return consistent
        }
        for index in 0..<written {
            ledger.ended(.automation, owner: 2, post: nil, startNanos: 0, runNanos: 500)
            flags.written.store(index + 1, ordering: .releasing)
            if index % 16 == 15 { await Task.yield() }
        }
        flags.stop.store(true, ordering: .releasing)
        #expect(await reader.value, "a snapshot counted a record twice, lost one, or saw one not written yet")
        ledger.fold()
        let snapshot = ledger.snapshot { _ in "storm" }
        #expect(snapshot.recorded + snapshot.dropped == UInt64(written))
        #expect(snapshot.pending == 0)
        #expect(snapshot.owners.first?.tasks == Int(snapshot.recorded))
    }

    /// The write path alone (``MainOwnerLedger/ended(_:owner:post:startNanos:runNanos:)``, the
    /// `main-task-ledger` perf-hot budget of 0.1 µs): every timed call writes a slot (the ring is
    /// folded between rounds, untimed), so none takes the drop path. The drop path is its own number.
    @Test func aLedgerWriteCostsUnderItsBudget() {
        let ledger = MainOwnerLedger(capacity: 1024, folding: .manual)
        let post = MainTaskPost(enqueueNanos: 1_000, node: .visible)
        let rounds = 100
        var timed: UInt64 = 0
        for _ in 0..<rounds {
            let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            for _ in 0..<ledger.capacity {
                ledger.ended(.visible, owner: 3, post: post, startNanos: 2_000, runNanos: 1_000)
            }
            timed &+= clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start
            ledger.fold()
        }
        let writes = rounds * ledger.capacity
        let perWrite = Double(timed) / Double(writes)
        let snapshot = ledger.snapshot { _ in "bench" }
        #expect(snapshot.dropped == 0, "every timed call wrote a slot")
        #expect(snapshot.recorded == UInt64(writes))

        let drops = 100_000
        let dropStart = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        for _ in 0..<(ledger.capacity + drops) {
            ledger.ended(.visible, owner: 3, post: post, startNanos: 2_000, runNanos: 1_000)
        }
        let perDrop = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - dropStart) / Double(ledger.capacity + drops)
        #expect(ledger.snapshot { _ in "bench" }.dropped == UInt64(drops))
        print("MainOwnerLedger.ended: \(String(format: "%.1f", perWrite)) ns per slot write, \(String(format: "%.1f", perDrop)) ns per call with the ring full")
        #if DEBUG
        #expect(perWrite < 2_000, "unoptimized build: a loose bound")
        #else
        #expect(perWrite < 100, "the perf-hot budget: 0.1 us per scheduled task")
        #endif
    }

    /// An off-main post's wait starts at the post, on the posting thread: time it spends waiting
    /// for the main run loop's hop counts (Chrome's `PendingTask::queue_time` at `PostTask`). The
    /// post is made from main, the same nonisolated path, so the hop cannot run before the clock moves.
    @Test func anOffMainPostsWaitIncludesTheHopToMain() throws {
        let clock = SendableLedgerClock()
        let board = MainTaskBoard(ledger: MainOwnerLedger(capacity: 64, folding: .manual))
        let work = MainWorkScheduler.testing(budget: MainFrameBudget(board: board, clock: { clock.read() })) { _ in LedgerTestLink() }
        let owner = work.board.owner("preview.reply")
        let flags = LedgerRace()
        work.postFromAnyThread(.visible, owner: owner) { flags.stop.store(true, ordering: .releasing) }
        // The main run loop has not run the hop yet: this time is the reply's wait.
        clock.advance(5_000_000)
        let end = Date(timeIntervalSinceNow: 5)
        while !flags.stop.load(ordering: .acquiring), Date() < end {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        let ran = flags.stop.load(ordering: .acquiring)  // #expect cannot take the noncopyable Atomic
        #expect(ran, "the post ran")
        let row = try #require(board.ownerSnapshot().owners.first { $0.owner == "preview.reply" })
        #expect(row.wait.count == 1)
        #expect(row.wait.maxNanos == 5_000_000, "the wait left out the time before the task reached main")
    }

    /// Returns once every block queued on the serial `queue` before it has run.
    private static func drain(_ queue: DispatchQueue) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { continuation.resume() }
        }
    }
}

/// What the racing threads share: how many records the producer wrote, and when to stop (or,
/// for the off-main post, that it ran).
private final class LedgerRace: Sendable {
    let written = Atomic<Int>(0)
    let stop = Atomic<Bool>(false)
}

/// A clock any thread reads (the budget's ``MainFrameBudget/postClock``); the test moves it.
private final class SendableLedgerClock: Sendable {
    private let now = Atomic<UInt64>(1_000_000_000)

    func read() -> UInt64 { now.load(ordering: .acquiring) }

    func advance(_ nanos: UInt64) { _ = now.add(nanos, ordering: .acquiringAndReleasing) }
}

@MainActor
private final class LedgerTestLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
