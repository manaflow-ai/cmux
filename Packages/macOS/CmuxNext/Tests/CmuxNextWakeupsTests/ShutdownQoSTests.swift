import CmuxNextCompat
@testable import CmuxNextWakeups
import Darwin
import Dispatch
import Testing

/// Shutdown raises block-shutdown work (plans/cmux-next/chrome-parity/p02-threads.md, task 118): quit waits for
/// it, so once shutdown starts a queued block-shutdown item runs at `.userInitiated` and a running one below
/// that gets one override on its thread, as Chrome runs BLOCK_SHUTDOWN tasks at a normal thread priority after
/// `TaskTracker::StartShutdown` (base/task/thread_pool/task_tracker.cc). The raise changes the QoS only: on the
/// files lane each level stays serial and the levels still run side by side. Skip and continue items are untouched.
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

    /// A flag lane bodies set and read.
    final class Flag: Sendable {
        private let value = Mutex(false)

        var isSet: Bool { value.withLock { $0 } }

        func set() { value.withLock { $0 = true } }
    }

    /// Counts the overrides the lanes start and end, and the threads (Mach ports) and levels they start them at.
    final class OverrideLog: Sendable {
        private let log = Mutex<(threads: [mach_port_t], levels: [WorkPriority], ends: Int)>(([], [], 0))
        /// Sent on each end, which runs on the item's thread just after the item: tests await it.
        let ended = Signal<Void>()

        var starts: Int { log.withLock { $0.threads.count } }
        var ends: Int { log.withLock { $0.ends } }
        var threads: [mach_port_t] { log.withLock { $0.threads } }
        var levels: [WorkPriority] { log.withLock { $0.levels } }

        var seam: ThreadQoSOverride {
            ThreadQoSOverride(
                start: { [self] thread, priority in
                    let raw = log.withLock { log -> UInt in
                        log.threads.append(thread)
                        log.levels.append(priority)
                        return UInt(log.threads.count)
                    }
                    return ThreadQoSOverride.Token(raw: raw)
                },
                end: { [self] _ in
                    log.withLock { $0.ends += 1 }
                    ended.send(())
                })
        }
    }

    /// One files slot per level, so a held slot makes the next item of its level queue.
    private func makeWork(_ label: String, overrides: OverrideLog) -> BackgroundWork {
        BackgroundWork(cpuWidth: 2, filesWidths: .serial, label: label, onQueued: { _, _ in }, uptimeNanos: nil,
                       taskHooks: .none, qosOverride: overrides.seam)
    }

    /// The Mach port of the calling lane thread, as the lanes record it.
    private static func currentThread() -> mach_port_t { pthread_mach_thread_np(pthread_self()) }

    /// The QoS class the calling lane thread runs at.
    private static func currentQoS() -> UInt32 { qos_class_self().rawValue }

    @Test func aQueuedIdleBlockItemRunsAtUserInitiatedOnItsOwnSlotOnceShutdownStarts() async {
        let overrides = OverrideLog()
        let work = makeWork("test.shutdown-qos.queued", overrides: overrides)
        let holding = Signal<Void>(), seen = Signal<UInt32>()
        let release = DispatchSemaphore(value: 0)
        // The idle slot of the files lane is busy until the test releases it.
        work.post(.idle, mayBlock: .files, shutdown: .continueOnShutdown) {
            holding.send(())
            release.wait()  // a lane may block; it holds the files lane's idle slot
        }
        await holding.next()
        work.post(.idle, mayBlock: .files, shutdown: .blockShutdown) { seen.send(Self.currentQoS()) }
        work.beginShutdown()
        // It keeps its level's slot, so it starts when the idle item ends, at .userInitiated.
        release.signal()
        let qos = await seen.next()
        #expect(qos == QOS_CLASS_USER_INITIATED.rawValue)
        // It started after shutdown, already at .userInitiated, so its thread needed no override.
        #expect(overrides.starts == 0)
        await work.shutdown()
    }

    /// A save posted after an earlier one at the same level never overtakes it at quit: on a level one slot wide
    /// the files lane runs one item at a time (``FilesLaneWidths``), and Chrome raises the thread, not the sequence.
    @Test func aQueuedBlockItemStillWaitsForTheRunningOneOfItsLevel() async {
        let overrides = OverrideLog()
        let work = makeWork("test.shutdown-qos.order", overrides: overrides)
        let firstRunning = Signal<Void>(), second = Signal<(firstEnded: Bool, qos: UInt32)>()
        let firstEnded = Flag()
        let release = DispatchSemaphore(value: 0)
        work.post(.bestEffort, mayBlock: .files, shutdown: .blockShutdown) {
            firstRunning.send(())
            release.wait()  // a lane may block; the older save holds the best-effort slot
            firstEnded.set()
        }
        await firstRunning.next()
        work.post(.bestEffort, mayBlock: .files, shutdown: .blockShutdown) {
            second.send((firstEnded.isSet, Self.currentQoS()))
        }
        work.beginShutdown()
        // A user-blocking item runs on its own slot meanwhile; had shutdown moved the queued save to that slot,
        // the save would have run (beside the older one) before this item.
        let userBlocking = Signal<Void>()
        work.post(.userBlocking, mayBlock: .files, shutdown: .blockShutdown) { userBlocking.send(()) }
        await userBlocking.next()
        release.signal()
        let seen = await second.next()
        #expect(seen?.firstEnded == true, "the newer save started while the older one still ran")
        #expect(seen?.qos == QOS_CLASS_USER_INITIATED.rawValue)
        await work.shutdown()
    }

    /// A raised block item does not queue behind unrelated work on the user-blocking slot.
    @Test func aFencedIdleBlockItemRunsWhileTheUserBlockingSlotHangs() async {
        let overrides = OverrideLog()
        let work = makeWork("test.shutdown-qos.hung", overrides: overrides)
        let holding = Signal<Void>(), seen = Signal<UInt32>()
        let release = DispatchSemaphore(value: 0)
        work.post(.userBlocking, mayBlock: .files, shutdown: .continueOnShutdown) {
            holding.send(())
            release.wait()  // a lane may block; a hung read holds the files lane's user-blocking slot
        }
        await holding.next()
        work.beginBestEffortFence()
        work.post(.idle, mayBlock: .files, shutdown: .blockShutdown) { seen.send(Self.currentQoS()) }
        work.beginShutdown()
        #expect(await seen.next() == QOS_CLASS_USER_INITIATED.rawValue)
        release.signal()
        await work.shutdown()
    }

    /// Block items queued at two levels run side by side after shutdown, each on its own level's slot.
    @Test func blockItemsQueuedAtTwoLevelsRunAtTheSameTime() async {
        let overrides = OverrideLog()
        let work = makeWork("test.shutdown-qos.parallel", overrides: overrides)
        let running = Signal<UInt32>()
        let release = DispatchSemaphore(value: 0)
        work.beginBestEffortFence()
        for priority in [WorkPriority.idle, .bestEffort] {
            work.post(priority, mayBlock: .files, shutdown: .blockShutdown) {
                running.send(Self.currentQoS())
                release.wait()  // a lane may block; each holds its level's slot until both run
            }
        }
        work.beginShutdown()
        // Both start while neither has ended: one serial slot for both would never send the second.
        let first = await running.next(), second = await running.next()
        #expect(first == QOS_CLASS_USER_INITIATED.rawValue)
        #expect(second == QOS_CLASS_USER_INITIATED.rawValue)
        release.signal()
        release.signal()
        await work.shutdown()
        #expect(overrides.starts == 0)
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
        let running = Signal<mach_port_t>()
        let release = DispatchSemaphore(value: 0)
        work.post(.bestEffort, mayBlock: .files, shutdown: .blockShutdown) {
            running.send(Self.currentThread())
            release.wait()  // a lane may block; it holds the files lane's best-effort slot
        }
        let thread = await running.next()
        work.beginShutdown()
        work.beginShutdown()  // a second start raises nothing more
        #expect(overrides.starts == 1)
        #expect(overrides.threads.first == thread, "the override is not on the item's thread")
        #expect(overrides.levels == [.userBlocking])
        #expect(overrides.ends == 0, "the override ended before the item")
        release.signal()
        await work.shutdown()
        // The item's end lifts the override, on its thread, right after the step that lets shutdown() return.
        await overrides.ended.next()
        #expect(overrides.ends == 1)
        #expect(overrides.starts == 1)
    }

    /// Shutdown starts between the claim of a best-effort block item and its begin on the slot thread: close() does
    /// not know the thread yet, so the begin puts the override on.
    @Test func anItemClaimedButNotBegunAtShutdownIsRaisedWhenItBegins() async {
        let overrides = OverrideLog()
        let claimed = Signal<Void>(), ran = Signal<mach_port_t>()
        let hold = DispatchSemaphore(value: 0)
        let scheduler = LaneScheduler(label: "test.shutdown-qos.claimed", policy: .perPriority(widths: [1, 1, 1, 1]),
                                      mayBlock: true,
                                      qosOverride: overrides.seam, hooks: .init(beforeBegin: { _ in
                                          claimed.send(())
                                          hold.wait()  // a test seam: holds the slot thread before the begin
                                      }))
        let job = LaneJob(id: 1, shutdown: .blockShutdown, work: { _ in ran.send(Self.currentThread()) },
                          abandoned: {}, done: {})
        guard case .started = scheduler.submit(job, at: .bestEffort, posted: true, unless: { false }) else {
            Issue.record("the item did not start on the free best-effort slot")
            return
        }
        await claimed.next()
        #expect(scheduler.close().isEmpty)
        #expect(overrides.starts == 0, "close() raised a thread it cannot know yet")
        hold.signal()
        let thread = await ran.next()
        await overrides.ended.next()
        #expect(overrides.starts == 1)
        #expect(overrides.threads.first == thread, "the override is not on the item's thread")
        #expect(overrides.ends == 1)
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
