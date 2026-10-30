import CmuxNextCompat
@testable import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Darwin
import Foundation
import Testing

/// The launch's best-effort fence (plans/cmux-next/chrome-parity/p02-threads.md, task 114; p06-scheduler.md, task 204):
/// raised once at the root, lowered once (the app's at the reveal, with no cap) or by its cap when it has one, lifted by
/// shutdown, with no timer while it is down. Chrome:
/// `ThreadPoolInstance::BeginBestEffortFence` / `EndBestEffortFence` (base/task/thread_pool/thread_pool_instance.h)
/// around startup (chrome/browser/after_startup_task_utils.cc).
@Suite(.timeLimit(.minutes(1))) struct BestEffortFenceTests {
    /// Values sent from lane bodies (synchronous), awaited by the async test in order.
    struct Signal<Value: Sendable>: Sendable {
        private let stream: AsyncStream<Value>
        private let continuation: AsyncStream<Value>.Continuation

        init() { (stream, continuation) = AsyncStream.makeStream(of: Value.self) }

        func send(_ value: Value) { continuation.yield(value) }

        func next() async -> Value? {
            for await value in stream { return value }
            return nil
        }
    }

    /// Priorities recorded from lane threads (the items that had to wait for a slot, or that ran), in order.
    nonisolated final class QueuedLog: Sendable {
        private let priorities = Mutex<[WorkPriority]>([])

        func record(_ priority: WorkPriority) { priorities.withLock { $0.append(priority) } }
        var all: [WorkPriority] { priorities.withLock { $0 } }
    }

    static func uptime() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    @Test func theCapIsThreeSeconds() {
        #expect(BackgroundWork.LaunchFence.cap == .seconds(3))
    }

    /// A best-effort item posted while the fence is up waits, and starts within 5 ms of the release: the release
    /// starts it, no timer or poll does. Best of three rounds, so one descheduled runner thread does not decide it.
    @Test func aHeldBestEffortItemStartsWithinFiveMillisecondsOfTheRelease() async throws {
        var best = UInt64.max
        for round in 0..<3 {
            let queued = Signal<WorkPriority>(), started = Signal<UInt64>()
            let work = BackgroundWork(label: "test.fence.release.\(round)", onQueued: { _, priority in queued.send(priority) })
            let fence = work.raiseLaunchFence(clock: ManualClock())
            work.post(.bestEffort, mayBlock: .files) { started.send(Self.uptime()) }
            // The files lane has free best-effort slots: only the fence makes the item wait.
            #expect(await queued.next() == .bestEffort)
            let released = Self.uptime()
            #expect(fence.lower())
            let start = try #require(await started.next())
            best = min(best, start - released)
        }
        #expect(best < 5_000_000, "best start \(best) ns after the release")
    }

    /// User-blocking work, posted or awaited, never waits for the fence; an awaited best-effort item neither.
    @Test func userBlockingAndAwaitedWorkStartAtOnce() async throws {
        let queued = QueuedLog(), ran = Signal<Void>()
        let work = BackgroundWork(label: "test.fence.user-blocking", onQueued: { _, priority in queued.record(priority) })
        let fence = work.raiseLaunchFence(clock: ManualClock())
        work.post(.userBlocking, mayBlock: .files) { ran.send(()) }
        _ = await ran.next()
        let answer = try await work.run(.userBlocking, mayBlock: .system) { () throws -> Int in 5 }
        let awaited = try await Task(priority: .background) {
            try await work.run(.bestEffort, mayBlock: .cpu) { () throws -> Int in 7 }
        }.value
        #expect(answer == 5 && awaited == 7)
        #expect(queued.all.isEmpty, "nothing waited while the fence was up")
        #expect(fence.isUp)
        fence.lower()
    }

    /// With no completion, the cap lowers the fence at 3 s and not before; the held items then run.
    @Test func theCapReleasesHeldWorkWithNoFrame() async throws {
        let clock = ManualClock()
        let queued = Signal<WorkPriority>(), ran = Signal<WorkPriority>()
        let work = BackgroundWork(label: "test.fence.cap", onQueued: { _, priority in queued.send(priority) })
        let fence = work.raiseLaunchFence(clock: clock)
        work.post(.idle, mayBlock: .files) { ran.send(.idle) }
        work.post(.bestEffort, mayBlock: .cpu) { ran.send(.bestEffort) }
        _ = await queued.next()
        _ = await queued.next()
        try await clock.waitForSleeper()
        clock.advance(by: BackgroundWork.LaunchFence.cap - .milliseconds(1))
        #expect(fence.isUp && fence.capArmed, "a millisecond short of the cap the fence holds")
        clock.advance(by: .milliseconds(1))
        let first = await ran.next(), second = await ran.next()
        #expect(Set([first, second].compactMap { $0 }) == Set([WorkPriority.idle, .bestEffort]))
        #expect(!fence.isUp)
        #expect(!fence.capArmed, "no timer once the fence is down")
        #expect(!fence.lower(), "the completion after the cap lowers nothing")
    }

    /// Lowering cancels the cap: no timer exists while the fence is down, and a second lower does nothing.
    @Test func loweringCancelsTheCap() async throws {
        let clock = ManualClock()
        let work = BackgroundWork(label: "test.fence.lower")
        let fence = work.raiseLaunchFence(clock: clock)
        try await clock.waitForSleeper()
        #expect(fence.capArmed)
        #expect(fence.lower())
        #expect(!fence.capArmed)
        #expect(work.state.withLock { $0.launchCaps.isEmpty })
        #expect(!fence.lower())
    }

    /// Shutdown lifts the fence, so a held block-shutdown item runs before `shutdown()` returns, and it cancels the
    /// cap.
    @Test func shutdownLiftsTheFenceAndCancelsTheCap() async throws {
        let clock = ManualClock()
        let work = BackgroundWork(label: "test.fence.shutdown")
        let fence = work.raiseLaunchFence(clock: clock)
        try await clock.waitForSleeper()
        let ran = QueuedLog()
        work.post(.bestEffort, mayBlock: .files, shutdown: .blockShutdown) { ran.record(.bestEffort) }
        await work.shutdown()
        #expect(ran.all == [.bestEffort], "the held block-shutdown item ran before shutdown returned")
        #expect(!fence.capArmed, "shutdown cancelled the cap")
    }

    /// A fence raised with no cap (the app's launch fence, lowered at the reveal) arms no timer: only ``lower()``
    /// releases its held items.
    @Test func aFenceRaisedWithNoCapArmsNoTimer() async {
        let queued = Signal<WorkPriority>(), ran = Signal<WorkPriority>()
        let work = BackgroundWork(label: "test.fence.no-cap", onQueued: { _, priority in queued.send(priority) })
        let fence = work.raiseLaunchFence(cap: nil)
        work.post(.bestEffort, mayBlock: .files) { ran.send(.bestEffort) }
        #expect(await queued.next() == .bestEffort)
        #expect(fence.isUp && !fence.capArmed)
        #expect(work.state.withLock { $0.launchCaps.isEmpty })
        #expect(fence.lower())
        #expect(await ran.next() == .bestEffort)
    }

    /// A fence raised after shutdown started arms no timer.
    @Test func aFenceRaisedAfterShutdownStartedArmsNoCap() {
        let work = BackgroundWork(label: "test.fence.late")
        work.beginShutdown()
        let fence = work.raiseLaunchFence(clock: ManualClock())
        #expect(!fence.capArmed)
        #expect(work.state.withLock { $0.launchCaps.isEmpty })
    }
}
