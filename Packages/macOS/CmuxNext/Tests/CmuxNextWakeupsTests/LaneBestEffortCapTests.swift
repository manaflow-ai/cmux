import CmuxNextCompat
@testable import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Dispatch
import Foundation
import Testing

/// The best-effort cap of a shared lane and the QoS of each level (plans/cmux-next/chrome-parity/p02-threads.md,
/// task 115): at most two best-effort and idle items run at once, at most one of them idle (Chrome's
/// `kMaxBestEffortTasks`, base/task/thread_pool/thread_pool_impl.cc), and user-visible work runs at user-initiated
/// QoS (Chrome's `kDefault` thread type, base/threading/platform_thread_apple.mm), while a user-visible child process
/// stays at default. On the system lane a low item past ``BackgroundWork/mayBlockThreshold`` stops counting
/// (Chrome's `ThreadGroup::BlockingStarted`, base/task/thread_pool/thread_group.cc).
///
/// Each test fails by its time limit when the guarantee breaks: the item it awaits would wait behind items that
/// only the test's final release lets end.
@Suite(.timeLimit(.minutes(1))) struct LaneBestEffortCapTests {
    /// Lane bodies (synchronous) report that they started or were queued; the async test awaits the reports.
    struct Signal: Sendable {
        private let stream: AsyncStream<Void>
        private let continuation: AsyncStream<Void>.Continuation

        init() { (stream, continuation) = AsyncStream.makeStream(of: Void.self) }

        func signal() { continuation.yield() }

        func wait(_ count: Int) async {
            var left = count
            guard left > 0 else { return }
            for await _ in stream {
                left -= 1
                if left == 0 { return }
            }
        }
    }

    /// How many lane bodies run now, and the most that ever ran at once.
    nonisolated final class Concurrency: Sendable {
        private let counts = Mutex((now: 0, most: 0))

        func enter() { counts.withLock { $0.now += 1; $0.most = max($0.most, $0.now) } }
        func leave() { counts.withLock { $0.now -= 1 } }
        var most: Int { counts.withLock { $0.most } }
    }

    /// A lane set whose system lane counts every low item for the whole test: its may-block clock never moves, so a
    /// slow runner never lets a hung item stop counting.
    static func stillClock(_ label: String, queued: Signal) -> BackgroundWork {
        BackgroundWork(cpuWidth: BackgroundWork.defaultCPUWidth, label: label,
                       onQueued: { lane, _ in if lane == .system { queued.signal() } },
                       uptimeNanos: nil, taskHooks: .none, mayBlockClock: ManualClock())
    }

    @Test func theCapIsChromesTwoWithOneIdle() {
        #expect(LaneScheduler.bestEffortCap == 2)
        #expect(LaneScheduler.idleCap == 1)
    }

    @Test func tenBestEffortItemsRunAtMostTwoAtOnceAndUserBlockingWorkStartsAtOnce() async throws {
        let queued = Signal(), started = Signal()
        let work = Self.stillClock("test.be-cap", queued: queued)
        let release = DispatchSemaphore(value: 0)
        let running = Concurrency()
        let count = 10
        for _ in 0..<count {
            work.post(.bestEffort, mayBlock: .system) {
                running.enter()
                started.signal()
                release.wait()
                running.leave()
            }
        }
        // Two items hang on their slots; the other eight wait for the cap while four slots stay free.
        await started.wait(LaneScheduler.bestEffortCap)
        await queued.wait(count - LaneScheduler.bestEffortCap)
        // Free slots still take user-visible and user-blocking work at once.
        let visible = try await work.run(.userVisible, mayBlock: .system) { () throws -> Int in 3 }
        let blocking = try await work.run(.userBlocking, mayBlock: .system) { () throws -> Int in 5 }
        #expect(visible == 3 && blocking == 5)
        for _ in 0..<count { release.signal() }
        await started.wait(count - LaneScheduler.bestEffortCap)
        #expect(running.most == LaneScheduler.bestEffortCap)
    }

    @Test func oneIdleItemRunsAndBestEffortTakesTheOtherCappedSlot() async throws {
        let queued = Signal(), started = Signal()
        let work = Self.stillClock("test.idle-cap", queued: queued)
        let release = DispatchSemaphore(value: 0)
        for _ in 0..<3 {
            work.post(.idle, mayBlock: .system) {
                started.signal()
                release.wait()
            }
        }
        // One idle item runs; the other two wait for the idle cap.
        await started.wait(LaneScheduler.idleCap)
        await queued.wait(2)
        // A best-effort item still takes the second capped slot; the next one waits for the cap.
        for _ in 0..<2 {
            work.post(.bestEffort, mayBlock: .system) {
                started.signal()
                release.wait()
            }
        }
        await started.wait(1)
        await queued.wait(1)
        let answer = try await work.run(.userBlocking, mayBlock: .system) { () throws -> Int in 7 }
        #expect(answer == 7)
        for _ in 0..<5 { release.signal() }
        // Every held item runs once the cap frees: two idle and one best effort.
        await started.wait(3)
    }

    @Test(arguments: [WorkPriority.bestEffort, .idle])
    func aLoneLowItemRunsOnACPULaneOfWidthOne(priority: WorkPriority) async {
        let ran = Signal()
        let work = BackgroundWork(cpuWidth: 1, label: "test.be-lone")
        work.post(priority, mayBlock: .cpu) { ran.signal() }
        await ran.wait(1)
    }

    @Test func userVisibleWorkRunsAtUserInitiatedAndBestEffortStaysUtility() {
        #expect(WorkPriority.userBlocking.qos == .userInitiated)
        #expect(WorkPriority.userVisible.qos == .userInitiated)
        #expect(WorkPriority.bestEffort.qos == .utility)
        #expect(WorkPriority.idle.qos == .background)
    }

    /// Thread pool QoS only: a child process and a ChildProcessLauncher spawn of a user-visible owner stay at
    /// default (Chrome sets a child's priority from what it shows, RenderProcessHostImpl::UpdateProcessPriority).
    @Test func aUserVisibleChildStaysAtDefault() {
        #expect(WorkPriority.userVisible.processQoS == .default)
        #expect(MayBlockPriority.userVisible.qos == .default)
        #expect(WorkPriority.userBlocking.processQoS == .userInitiated)
    }

    @Test func aUserVisibleItemRunsOnAUserInitiatedThread() async throws {
        let work = BackgroundWork(label: "test.uv-qos")
        // Awaited from a task at user-visible, so the item is not boosted to the test runner's priority; the
        // result comes back through a stream, as awaiting the task's value would escalate it.
        let (reports, report) = AsyncStream.makeStream(of: (queue: String, qos: UInt32).self,
                                                       bufferingPolicy: .bufferingNewest(1))
        Task(priority: .medium) {
            defer { report.finish() }
            report.yield(try await work.run(.userVisible, mayBlock: .files) {
                (String(cString: __dispatch_queue_get_label(nil)), qos_class_self().rawValue)
            })
        }
        var iterator = reports.makeAsyncIterator()
        let seen = try #require(await iterator.next())
        #expect(seen.queue.hasPrefix("test.uv-qos.files.userVisible."), "ran on \(seen.queue)")
        #expect(seen.qos == QOS_CLASS_USER_INITIATED.rawValue)
    }

    @Test(arguments: [WorkPriority.bestEffort, .idle])
    func twoHungLowSystemItemsStopCountingAfterTheMayBlockThreshold(priority: WorkPriority) async throws {
        let clock = ManualClock()
        let queued = Signal(), started = Signal()
        let work = BackgroundWork(cpuWidth: 2, label: "test.be-mayblock",
                                  onQueued: { lane, _ in if lane == .system { queued.signal() } },
                                  uptimeNanos: nil, taskHooks: .none, mayBlockClock: clock)
        let release = DispatchSemaphore(value: 0)
        let hung = priority == .idle ? LaneScheduler.idleCap : LaneScheduler.bestEffortCap
        for _ in 0..<hung + 1 {
            work.post(priority, mayBlock: .system) {
                started.signal()
                release.wait()
            }
        }
        // The cap's items hang; the next one waits for the cap, and the lane sets one timer to the threshold.
        await started.wait(hung)
        await queued.wait(1)
        try await clock.waitForSleeper()
        #expect(clock.sleepRequests.last?.deadline == ManualClock.Instant(offset: BackgroundWork.mayBlockThreshold))
        // Past the threshold the hung items stop counting, as Chrome's blocked best-effort tasks do: the held one starts.
        clock.advance(by: BackgroundWork.mayBlockThreshold)
        await started.wait(1)
        for _ in 0..<hung + 1 { release.signal() }
    }

    @Test func theCPULaneCountsALowItemForItsWholeRun() async throws {
        let clock = ManualClock()
        let queued = Signal(), started = Signal()
        let work = BackgroundWork(cpuWidth: 4, label: "test.be-cpu",
                                  onQueued: { lane, _ in if lane == .cpu { queued.signal() } },
                                  uptimeNanos: nil, taskHooks: .none, mayBlockClock: clock)
        let release = DispatchSemaphore(value: 0)
        for _ in 0..<LaneScheduler.bestEffortCap + 1 {
            work.post(.bestEffort, mayBlock: .cpu) {
                started.signal()
                release.wait()
            }
        }
        await started.wait(LaneScheduler.bestEffortCap)
        await queued.wait(1)
        // No may-block compensation on the cpu lane (its items may not block): nothing sleeps on the clock.
        #expect(clock.sleepRequests.isEmpty)
        for _ in 0..<LaneScheduler.bestEffortCap + 1 { release.signal() }
        await started.wait(1)
    }

    @Test func closingTheLaneLiftsTheCapForBlockShutdownItems() async {
        let queued = Signal(), started = Signal()
        let work = Self.stillClock("test.be-close", queued: queued)
        let release = DispatchSemaphore(value: 0)
        for _ in 0..<LaneScheduler.bestEffortCap + 1 {
            work.post(.bestEffort, mayBlock: .system, shutdown: .blockShutdown) {
                started.signal()
                release.wait()
            }
        }
        await started.wait(LaneScheduler.bestEffortCap)
        await queued.wait(1)
        // Quit waits for block-shutdown items: after beginShutdown the held one starts beside the hung ones.
        work.beginShutdown()
        await started.wait(1)
        for _ in 0..<LaneScheduler.bestEffortCap + 1 { release.signal() }
        await work.shutdown()
    }
}
