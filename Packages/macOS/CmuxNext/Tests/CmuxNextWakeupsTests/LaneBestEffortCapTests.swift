import CmuxNextCompat
@testable import CmuxNextWakeups
import Dispatch
import Foundation
import Testing

/// The best-effort cap of a shared lane and the QoS of each level (plans/cmux-next/chrome-parity/p02-threads.md,
/// task 115): at most two best-effort and idle items run at once, at most one of them idle (Chrome's
/// `kMaxBestEffortTasks`, base/task/thread_pool/thread_pool_impl.cc), and user-visible work runs at user-initiated
/// QoS (Chrome's `kDefault` thread type, base/threading/platform_thread_apple.mm).
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

    @Test func theCapIsChromesTwoWithOneIdle() {
        #expect(LaneScheduler.bestEffortCap == 2)
        #expect(LaneScheduler.idleCap == 1)
    }

    @Test func tenBestEffortItemsRunAtMostTwoAtOnceAndUserBlockingWorkStartsAtOnce() async throws {
        let queued = Signal(), started = Signal()
        let work = BackgroundWork(label: "test.be-cap", onQueued: { lane, _ in if lane == .system { queued.signal() } })
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
        let work = BackgroundWork(label: "test.idle-cap", onQueued: { lane, _ in if lane == .system { queued.signal() } })
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
        #expect(WorkPriority.userVisible.processQoS == .userInitiated)
        #expect(MayBlockPriority.userVisible.qos == .userInitiated)
    }

    @Test func aUserVisibleItemRunsOnAUserInitiatedThread() async throws {
        let work = BackgroundWork(label: "test.uv-qos")
        let qos = try await work.run(.userVisible, mayBlock: .files) { qos_class_self().rawValue }
        #expect(qos == QOS_CLASS_USER_INITIATED.rawValue)
    }
}
