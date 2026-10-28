import CmuxNextCompat
import CmuxNextWakeups
import Darwin
import Dispatch
import Foundation
import os
import Testing

/// Task traits (plans/cmux-next/threading-model.md): blocking work runs on BackgroundWork's lanes, never on the
/// cooperative pool, at its stated QoS; a higher-priority waiter boosts it; nothing here makes the main thread wait.
/// A best-effort fence holds posted idle and best-effort items until it ends, never awaited ones, and never changes QoS.
@Suite(.timeLimit(.minutes(1))) struct BackgroundWorkTests {
    /// Where a lane body ran: its dispatch queue label and its thread's QoS.
    struct Seen: Sendable {
        var queue: String
        var qos: qos_class_t

        static func here() -> Seen {
            Seen(queue: String(cString: __dispatch_queue_get_label(nil)), qos: qos_class_self())
        }
    }

    /// Lane bodies (synchronous) report that they started; the async test awaits the reports.
    struct Started: Sendable {
        private let stream: AsyncStream<Void>
        private let continuation: AsyncStream<Void>.Continuation

        init() { (stream, continuation) = AsyncStream.makeStream(of: Void.self) }

        func signal() { continuation.yield() }

        func wait(_ count: Int = 1) async {
            var left = count
            for await _ in stream {
                left -= 1
                if left == 0 { return }
            }
        }
    }

    @Test(arguments: BlockingLane.allCases, WorkPriority.allCases)
    func aMayBlockItemRunsOnItsLaneAtItsQoSNeverOnTheCooperativePool(lane: BlockingLane, priority: WorkPriority) async throws {
        let work = BackgroundWork(cpuWidth: 2, label: "test.work")
        // Posted, not awaited: an awaiting caller would boost the item to its own priority.
        let (reports, report) = AsyncStream.makeStream(of: Seen.self)
        work.post(priority, mayBlock: lane) { report.yield(Seen.here()) }
        var iterator = reports.makeAsyncIterator()
        let seen = try #require(await iterator.next())
        #expect(seen.queue.hasPrefix("test.work.\(lane)."), "ran on \(seen.queue)")
        if lane == .files { #expect(seen.queue.hasPrefix("test.work.files.\(priority)."), "ran on \(seen.queue)") }
        #expect(!seen.queue.contains("cooperative"))
        #expect(seen.qos == priority.qos.qosClass.rawValue)
    }

    @Test func blockedLaneItemsLeaveTheCooperativePoolFree() async throws {
        // More blocked items than the pool has threads, every one at userBlocking, the burst's own QoS (the
        // pool is per QoS): on the pool they would hold every userInitiated thread and the burst could not run.
        let blockers = ProcessInfo.processInfo.activeProcessorCount + 2
        let work = BackgroundWork(cpuWidth: blockers, label: "test.pool")
        let release = DispatchSemaphore(value: 0)
        let started = Started()
        for _ in 0..<blockers {
            work.post(.userBlocking, mayBlock: .cpu) {
                started.signal()
                release.wait()
            }
        }
        // Every blocker holds its thread before the burst starts.
        await started.wait(blockers)
        let count = ProcessInfo.processInfo.activeProcessorCount * 4
        let done = await withTaskGroup(of: Int.self) { group in
            for index in 0..<count { group.addTask(priority: .high) { index } }
            var finished = 0
            for await _ in group { finished += 1 }
            return finished
        }
        #expect(done == count)
        for _ in 0..<blockers { release.signal() }
    }

    @Test func theCPULaneRunsUpToItsWidthAtOnce() async throws {
        let work = BackgroundWork(cpuWidth: 3, label: "test.cpu")
        let arrived = OSAllocatedUnfairLock(initialState: 0)
        let all = DispatchSemaphore(value: 0)
        // Each item waits until all three run: it passes only when the lane runs three at once. User-visible,
        // as best effort runs at most two at once (LaneScheduler.bestEffortCap, task 115).
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<3 {
                group.addTask {
                    try await work.run(.userVisible, mayBlock: .cpu) {
                        if arrived.withLock({ $0 += 1; return $0 }) == 3 { for _ in 0..<3 { all.signal() } }
                        all.wait()
                    }
                }
            }
            try await group.waitForAll()
        }
    }

    @Test func aWaiterAbovePriorityBoostsTheItemPastBlockedLowerWork() async throws {
        let work = BackgroundWork(filesWidths: .serial, label: "test.boost")
        let release = DispatchSemaphore(value: 0)
        let blocked = Started()
        // The one best-effort slot of the files lane is held.
        work.post(.bestEffort, mayBlock: .files) {
            blocked.signal()
            release.wait()
        }
        await blocked.wait()
        // A user-blocking caller asks for best-effort work: it runs at the caller's priority, on the
        // user-blocking slot, while the best-effort slot is still held (else this await never returns).
        // The Task's result type picks the async `run`; the non-async one returns a `Pending`.
        let seen = try await Task(priority: .high) { () async throws -> Seen in
            try await work.run(.bestEffort, mayBlock: .files) { Seen.here() }
        }.value
        #expect(seen.queue.hasPrefix("test.boost.files.userBlocking."), "ran on \(seen.queue)")
        #expect(seen.qos == QOS_CLASS_USER_INITIATED)
        release.signal()
    }

    @MainActor @Test func theMainActorKeepsRunningWhileItAwaitsBestEffortWork() async throws {
        let work = BackgroundWork(label: "test.main")
        let release = DispatchSemaphore(value: 0)
        let ran = OSAllocatedUnfairLock(initialState: false)
        // The main actor awaits a best-effort item that cannot finish until a main-actor probe has run:
        // a synchronous wait (the inversion) would deadlock here; the await lets the probe run.
        async let result: Bool = try work.run(.bestEffort, mayBlock: .system) {
            release.wait()
            return ran.withLock { $0 }
        }
        await Task { @MainActor in
            ran.withLock { $0 = true }
            release.signal()
        }.value
        #expect(try await result)
    }

    @Test func aCancelledQueuedItemNeverRuns() async throws {
        let queued = Started()
        // One slot per priority, so the item behind the held one queues.
        let work = BackgroundWork(filesWidths: .serial, label: "test.cancel", onQueued: { _, _ in queued.signal() })
        let release = DispatchSemaphore(value: 0)
        let blocked = Started()
        work.post(.bestEffort, mayBlock: .files) {
            blocked.signal()
            release.wait()
        }
        await blocked.wait()
        let ran = OSAllocatedUnfairLock(initialState: false)
        let waiter = Task(priority: .utility) {
            try await work.run(.bestEffort, mayBlock: .files) { ran.withLock { $0 = true } }
        }
        // Cancel only once the item is queued, so the cancel handler takes it out of the queue (not the
        // check at the call).
        await queued.wait()
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        release.signal()
        // The lane drains: a later item on the same slot runs, the cancelled one did not.
        try await Task(priority: .utility) { try await work.run(.bestEffort, mayBlock: .files) {} }.value
        #expect(!ran.withLock { $0 })
    }

    @Test func shutdownWaitsForBlockShutdownItemsAndDropsTheRest() async throws {
        // One slot per priority, so the items behind the held one queue.
        let work = BackgroundWork(filesWidths: .serial, label: "test.shutdown")
        let release = DispatchSemaphore(value: 0)
        let blocked = Started()
        let log = OSAllocatedUnfairLock<[String]>(initialState: [])
        // Everything at userBlocking, the top level: no await can boost an item past the held slot.
        work.post(.userBlocking, mayBlock: .files) {
            blocked.signal()
            release.wait()
        }
        await blocked.wait()
        work.post(.userBlocking, mayBlock: .files, shutdown: .skipOnShutdown) { log.withLock { $0.append("skip") } }
        work.post(.userBlocking, mayBlock: .files, shutdown: .blockShutdown) { log.withLock { $0.append("save") } }
        let reader = Task(priority: .high) {
            try await work.run(.userBlocking, mayBlock: .files) { log.withLock { $0.append("read") } }
        }
        async let shutdown: Void = work.shutdown()
        await #expect(throws: CancellationError.self) { try await reader.value }
        release.signal()
        await shutdown
        #expect(log.withLock { $0 } == ["save"])
        // After shutdown a new item that may be skipped is refused.
        await #expect(throws: CancellationError.self) { try await work.run(.userBlocking, mayBlock: .system) {} }
    }

    /// The levels a best-effort fence holds.
    static let fencedLevels: [WorkPriority] = [.idle, .bestEffort]

    @Test(arguments: BlockingLane.allCases, BackgroundWorkTests.fencedLevels)
    func aFencedPostedItemRunsOnlyAfterTheFenceEndsAtItsOwnQoS(lane: BlockingLane, priority: WorkPriority) async throws {
        let queued = Started()
        let work = BackgroundWork(cpuWidth: 2, label: "test.fence", onQueued: { _, _ in queued.signal() })
        let ran = OSAllocatedUnfairLock(initialState: false)
        let (reports, report) = AsyncStream.makeStream(of: Seen.self)
        work.beginBestEffortFence()
        work.post(priority, mayBlock: lane) {
            ran.withLock { $0 = true }
            report.yield(Seen.here())
        }
        // Queued, not started, although its slot is free.
        await queued.wait()
        // The lane still runs work the fence does not hold, while the fenced item waits.
        try await Task(priority: .high) { try await work.run(.userBlocking, mayBlock: lane) {} }.value
        #expect(!ran.withLock { $0 })
        work.endBestEffortFence()
        var iterator = reports.makeAsyncIterator()
        let seen = try #require(await iterator.next())
        #expect(seen.queue.hasPrefix("test.fence.\(lane)."), "ran on \(seen.queue)")
        if lane == .files { #expect(seen.queue.hasPrefix("test.fence.files.\(priority)."), "ran on \(seen.queue)") }
        #expect(seen.qos == priority.qos.qosClass.rawValue)
    }

    @Test(arguments: BlockingLane.allCases, BackgroundWorkTests.fencedLevels)
    func anAwaitedFencedItemCompletesAtItsOwnQoS(lane: BlockingLane, priority: WorkPriority) async throws {
        let work = BackgroundWork(cpuWidth: 2, label: "test.fenceawait")
        work.beginBestEffortFence()
        // Awaited from a task at the item's own level, so no boost: it passes the fence unchanged. The
        // test reads the result from a stream, since awaiting the task's value would escalate it.
        let (reports, report) = AsyncStream.makeStream(of: Seen.self)
        Task(priority: priority.taskPriority) {
            defer { report.finish() }
            report.yield(try await work.run(priority, mayBlock: lane) { Seen.here() })
        }
        var iterator = reports.makeAsyncIterator()
        let seen = try #require(await iterator.next())
        if lane == .files { #expect(seen.queue.hasPrefix("test.fenceawait.files.\(priority)."), "ran on \(seen.queue)") }
        #expect(seen.qos == priority.qos.qosClass.rawValue)
        work.endBestEffortFence()
    }

    @Test(arguments: [WorkPriority.userVisible, .userBlocking])
    func theFenceDoesNotHoldPostedWorkAboveBestEffort(priority: WorkPriority) async throws {
        let work = BackgroundWork(label: "test.fenceabove")
        work.beginBestEffortFence()
        let (reports, report) = AsyncStream.makeStream(of: Seen.self)
        work.post(priority, mayBlock: .files) { report.yield(Seen.here()) }
        var iterator = reports.makeAsyncIterator()
        let seen = try #require(await iterator.next())
        #expect(seen.queue.hasPrefix("test.fenceabove.files.\(priority)."), "ran on \(seen.queue)")
        #expect(seen.qos == priority.qos.qosClass.rawValue)
    }

    @Test func fencesNestAndHeldItemsRunInPostOrder() async throws {
        let queued = Started()
        // One slot per priority: held items of one priority then start one after another, in post order.
        let work = BackgroundWork(filesWidths: .serial, label: "test.fencenest", onQueued: { _, _ in queued.signal() })
        let log = OSAllocatedUnfairLock<[String]>(initialState: [])
        let finished = Started()
        work.beginBestEffortFence()
        work.beginBestEffortFence()
        for name in ["a", "b", "c"] {
            work.post(.bestEffort, mayBlock: .files) {
                log.withLock { $0.append(name) }
                finished.signal()
            }
        }
        await queued.wait(3)
        work.endBestEffortFence()
        // One fence is still up: a probe on the lane runs, the held items do not.
        try await Task(priority: .high) { try await work.run(.userBlocking, mayBlock: .files) {} }.value
        #expect(log.withLock { $0 }.isEmpty)
        work.endBestEffortFence()
        await finished.wait(3)
        #expect(log.withLock { $0 } == ["a", "b", "c"])
        // An extra end does nothing, and later posts run at once.
        work.endBestEffortFence()
        work.post(.bestEffort, mayBlock: .files) { finished.signal() }
        await finished.wait()
    }

    @Test func shutdownLiftsTheFenceForBlockShutdownItems() async throws {
        let queued = Started()
        let work = BackgroundWork(label: "test.fenceshutdown", onQueued: { _, _ in queued.signal() })
        let log = OSAllocatedUnfairLock<[String]>(initialState: [])
        work.beginBestEffortFence()
        work.post(.bestEffort, mayBlock: .files, shutdown: .skipOnShutdown) { log.withLock { $0.append("skip") } }
        work.post(.idle, mayBlock: .files, shutdown: .blockShutdown) { log.withLock { $0.append("save") } }
        await queued.wait(2)
        // Returns only when the held block-shutdown save has run.
        await work.shutdown()
        #expect(log.withLock { $0 } == ["save"])
    }

    /// `onRan` reports each item's lane, priority and run (the startup trace's lane slices) until
    /// `stopReportingRuns()`; items submitted after it do not report.
    @Test func onRanReportsEachItemUntilRunsStopBeingReported() async throws {
        let reports = OSAllocatedUnfairLock<[(BlockingLane, WorkPriority, UInt64, UInt64)]>(initialState: [])
        let work = BackgroundWork(filesWidths: .serial, label: "test.onran", onRan: { lane, priority, start, end in
            reports.withLock { $0.append((lane, priority, start, end)) }
        })
        // One user-visible files slot: an item's report runs before the next item's body.
        let ran = Started()
        work.post(.userVisible, mayBlock: .files) {}
        work.post(.userVisible, mayBlock: .files) { ran.signal() }
        await ran.wait()
        let first = try #require(reports.withLock { $0.first })
        #expect(first.0 == .files)
        #expect(first.1 == .userVisible)
        #expect(first.3 >= first.2)
        work.stopReportingRuns()
        work.post(.userVisible, mayBlock: .files) { ran.signal() }
        await ran.wait()
        let before = reports.withLock { $0.count }
        #expect(before == 2)
        work.post(.userVisible, mayBlock: .files) {}
        work.post(.userVisible, mayBlock: .files) { ran.signal() }
        await ran.wait()
        #expect(reports.withLock { $0.count } == before)
    }

    @Test(arguments: MainWorkClass.allCases)
    func everyMainWorkClassMapsToOneWorkPriority(workClass: MainWorkClass) {
        let expected: WorkPriority = switch workClass {
        case .input, .frame, .userBlocking: .userBlocking
        case .visible: .userVisible
        case .automation, .background, .idle: .bestEffort
        }
        #expect(WorkPriority(workClass) == expected)
        #expect(WorkPriority(WorkPriority(workClass).taskPriority) == expected)
    }
}
