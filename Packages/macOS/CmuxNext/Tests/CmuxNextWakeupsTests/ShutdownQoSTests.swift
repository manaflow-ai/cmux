import CmuxNextCompat
@testable import CmuxNextWakeups
import Darwin
import Dispatch
import Testing

/// Shutdown raises block-shutdown work (plans/cmux-next/chrome-parity/p02-threads.md, task 118): quit waits for
/// it, so once shutdown starts a queued block-shutdown item runs at `.userInitiated` and a running one below
/// that gets one override on its thread, as Chrome runs BLOCK_SHUTDOWN tasks at a normal thread priority after
/// `TaskTracker::StartShutdown` (base/task/thread_pool/task_tracker.cc). Skip and continue items are untouched.
@Suite(.timeLimit(.minutes(1))) struct ShutdownQoSTests {
    /// Lane bodies (synchronous) report; the async test awaits the reports (no polling, no sleep).
    struct Signal<Value: Sendable>: Sendable {
        private let stream: AsyncStream<Value>
        private let continuation: AsyncStream<Value>.Continuation

        init() { (stream, continuation) = AsyncStream.makeStream(of: Value.self) }

        func send(_ value: Value) { continuation.yield(value) }

        /// The next value sent; nil when the awaiting task is cancelled.
        @discardableResult
        func next() async -> Value? {
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()
        }
    }

    /// Counts the overrides the lanes start and end, and the threads they start them on.
    final class OverrideLog: Sendable {
        private let log = Mutex<(threads: [UInt], ends: Int)>(([], 0))
        /// Sent on each end, which runs on the item's thread just after the item: tests await it.
        let ended = Signal<Void>()

        var starts: Int { log.withLock { $0.threads.count } }
        var ends: Int { log.withLock { $0.ends } }
        var threads: [UInt] { log.withLock { $0.threads } }

        var seam: LaneQoSOverride {
            LaneQoSOverride { [self] thread in
                let address = UInt(bitPattern: thread)
                log.withLock { $0.threads.append(address) }
                return { [self] in
                    log.withLock { $0.ends += 1 }
                    ended.send(())
                }
            }
        }
    }

    private func makeWork(_ label: String, overrides: OverrideLog) -> BackgroundWork {
        BackgroundWork(cpuWidth: 2, label: label, onQueued: { _, _ in }, uptimeNanos: nil, taskHooks: .none,
                       qosOverride: overrides.seam)
    }

    /// The QoS class the calling lane thread runs at.
    private static func currentQoS() -> UInt32 { qos_class_self().rawValue }

    @Test func aQueuedIdleBlockItemRunsAtUserInitiatedOnceShutdownStarts() async {
        let overrides = OverrideLog()
        let work = makeWork("test.shutdown-qos.queued", overrides: overrides)
        let holding = Signal<Void>(), seen = Signal<UInt32>()
        let release = DispatchSemaphore(value: 0)
        // The idle slot of the files lane is busy until the end of the test.
        work.post(.idle, mayBlock: .files, shutdown: .continueOnShutdown) {
            holding.send(())
            release.wait()  // a lane may block; it holds the files lane's idle slot
        }
        await holding.next()
        work.post(.idle, mayBlock: .files, shutdown: .blockShutdown) { seen.send(Self.currentQoS()) }
        work.beginShutdown()
        // It runs while the idle slot still holds: shutdown moved it to the user-blocking list.
        let qos = await seen.next()
        #expect(qos == QOS_CLASS_USER_INITIATED.rawValue)
        // It never ran below user-blocking, so its thread needed no override.
        #expect(overrides.starts == 0)
        release.signal()
        await work.shutdown()
    }

    @Test func aFencedBestEffortBlockItemRunsAtUserInitiatedOnceShutdownStarts() async {
        let overrides = OverrideLog()
        let work = makeWork("test.shutdown-qos.fenced", overrides: overrides)
        let seen = Signal<UInt32>()
        work.beginBestEffortFence()
        work.post(.bestEffort, mayBlock: .cpu, shutdown: .blockShutdown) { seen.send(Self.currentQoS()) }
        await work.shutdown()
        #expect(await seen.next() == QOS_CLASS_USER_INITIATED.rawValue)
        #expect(overrides.starts == 0)
    }

    @Test func aBlockItemSubmittedAfterShutdownStartsRunsAtUserInitiated() async throws {
        let overrides = OverrideLog()
        let work = makeWork("test.shutdown-qos.late", overrides: overrides)
        work.beginShutdown()
        let qos = try await Task(priority: .background) {
            try await work.run(.idle, mayBlock: .files, shutdown: .blockShutdown) { Self.currentQoS() }
        }.value
        #expect(qos == QOS_CLASS_USER_INITIATED.rawValue)
        await work.shutdown()
    }

    @Test func aRunningBestEffortBlockItemGetsExactlyOneOverride() async {
        let overrides = OverrideLog()
        let work = makeWork("test.shutdown-qos.running", overrides: overrides)
        let running = Signal<UInt>()
        let release = DispatchSemaphore(value: 0)
        work.post(.bestEffort, mayBlock: .files, shutdown: .blockShutdown) {
            running.send(UInt(bitPattern: pthread_self()))
            release.wait()  // a lane may block; it holds the files lane's best-effort slot
        }
        let thread = await running.next()
        work.beginShutdown()
        work.beginShutdown()  // a second start raises nothing more
        #expect(overrides.starts == 1)
        #expect(overrides.threads.first == thread, "the override is not on the item's thread")
        #expect(overrides.ends == 0, "the override ended before the item")
        release.signal()
        await work.shutdown()
        // The item's end lifts the override, on its thread, right after the step that lets shutdown() return.
        await overrides.ended.next()
        #expect(overrides.ends == 1)
        #expect(overrides.starts == 1)
    }

    @Test func runningSkipContinueAndUserBlockingItemsGetNoOverride() async {
        let overrides = OverrideLog()
        let work = makeWork("test.shutdown-qos.untouched", overrides: overrides)
        let running = Signal<Void>()
        let release = DispatchSemaphore(value: 0)
        let behaviors: [(WorkPriority, ShutdownBehavior)] = [
            (.bestEffort, .skipOnShutdown), (.idle, .continueOnShutdown), (.userBlocking, .blockShutdown),
        ]
        for (priority, shutdown) in behaviors {
            work.post(priority, mayBlock: .files, shutdown: shutdown) {
                running.send(())
                release.wait()  // a lane may block; each holds its own priority's files slot
            }
        }
        for _ in behaviors { await running.next() }
        // A queued skip item behind the busy best-effort slot is still dropped, not raised.
        let dropped = Signal<Bool>()
        work.post(.bestEffort, mayBlock: .files, shutdown: .skipOnShutdown, abandoned: { dropped.send(true) }) {
            dropped.send(false)
        }
        work.beginShutdown()
        #expect(await dropped.next() == true, "shutdown ran a queued skip item")
        #expect(overrides.starts == 0)
        for _ in behaviors { release.signal() }
        await work.shutdown()
        #expect(overrides.starts == 0)
    }
}
