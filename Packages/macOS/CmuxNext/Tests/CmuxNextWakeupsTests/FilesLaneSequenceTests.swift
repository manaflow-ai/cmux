import CmuxNextCompat
import CmuxNextWakeups
import Darwin
import Dispatch
import Foundation
import Testing

/// The files lane runs several items of each priority at once (4/3/2/1, ``FilesLaneWidths``), and ordered work
/// goes through a ``WorkSequence``: in post order, never two at once, on any free slot, each at its own priority
/// (plans/cmux-next/chrome-parity/p02-threads.md, task 116; Chrome's `SequencedTaskRunner` on the thread pool).
///
/// A test whose guarantee breaks fails by its time limit: its item would wait behind work only the test's final
/// release lets end.
@Suite(.timeLimit(.minutes(1))) struct FilesLaneSequenceTests {
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

    /// A value lane bodies and the test share.
    final class Box<Value: Sendable>: Sendable {
        private let mutex: Mutex<Value>

        init(_ value: Value) { mutex = Mutex(value) }

        func withLock<R>(_ body: (inout sending Value) -> sending R) -> sending R { mutex.withLock(body) }
    }

    /// What the items of a test did, in the order they did it.
    final class Log: Sendable {
        private let state = Mutex<[String]>([])

        func add(_ entry: String) { state.withLock { $0.append(entry) } }

        var entries: [String] { state.withLock { $0 } }
    }

    @Test func theFilesLaneRunsFourThreeTwoOneByPriority() {
        let widths = BackgroundWork(label: "test.files-widths-default").filesWidths
        #expect(widths == .standard)
        #expect(WorkPriority.allCases.reversed().map(widths.width) == [4, 3, 2, 1])
    }

    @Test(arguments: WorkPriority.allCases)
    func eachPriorityRunsItsWidthAtOnceAndQueuesTheNext(priority: WorkPriority) async {
        let queued = Signal(), started = Signal(), ran = Signal()
        let work = BackgroundWork(label: "test.files-width", onQueued: { lane, level in
            if lane == .files && level == priority { queued.signal() }
        })
        let width = FilesLaneWidths.standard.width(priority)
        let release = DispatchSemaphore(value: 0)
        for _ in 0..<width {
            work.post(priority, mayBlock: .files) {
                started.signal()
                release.wait()
            }
        }
        // All of them run at once; with fewer slots this never returns.
        await started.wait(width)
        work.post(priority, mayBlock: .files) { ran.signal() }
        // One more waits for a slot of its own priority.
        await queued.wait(1)
        for _ in 0..<width { release.signal() }
        await ran.wait(1)
    }

    @Test func aSecondUserBlockingReadEndsWithinTenMillisecondsWhileTheFirstBlocks() async throws {
        let work = BackgroundWork(label: "test.files-parallel")
        let started = Signal()
        let firstRunning = Box(false)
        let first = Task(priority: .high) {
            try await work.run(.userBlocking, mayBlock: .files) {
                firstRunning.withLock { $0 = true }
                started.signal()
                // A slow disk read: the slot is held for 200 ms.
                _ = DispatchSemaphore(value: 0).wait(timeout: .now() + .milliseconds(200))
                firstRunning.withLock { $0 = false }
            }
        }
        await started.wait(1)
        let clock = ContinuousClock()
        let start = clock.now
        let answer = try await Task(priority: .high) {
            try await work.run(.userBlocking, mayBlock: .files) { () throws -> Int in 42 }
        }.value
        let elapsed = clock.now - start
        #expect(answer == 42)
        #expect(firstRunning.withLock { $0 }, "the second read waited for the first")
        #expect(elapsed < .milliseconds(10), "the second read took \(elapsed)")
        try await first.value
    }

    @Test func aHundredSequencedWritesLandInOrderWithNoOverlap() async throws {
        let work = BackgroundWork(label: "test.sequence-writes")
        let sequence = work.sequence("test.writes")
        #expect(sequence.lane == .files)
        let file = FileManager.default.temporaryDirectory.appending(path: "sequence-writes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data().write(to: file)
        let inside = Box(0), overlaps = Box(0)
        let done = Signal()
        // Three priorities, each on slots of its own: the order holds across them. Idle runs throttled, so it is left out.
        let levels: [WorkPriority] = [.bestEffort, .userVisible, .userBlocking]
        for index in 0..<100 {
            sequence.post(levels[index % levels.count]) {
                if inside.withLock({ $0 += 1; return $0 }) > 1 { overlaps.withLock { $0 += 1 } }
                // A read, change and write: two at once would lose a line, a wrong order would swap two.
                var text = (try? String(blockingContentsOf: file, encoding: .utf8)) ?? ""
                text += "\(index)\n"
                try? Data(text.utf8).blockingWrite(to: file, options: .atomic)
                inside.withLock { $0 -= 1 }
                done.signal()
            }
        }
        await done.wait(100)
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map { Int($0) }
        #expect(lines == (0..<100).map { Optional($0) })
        #expect(overlaps.withLock { $0 } == 0)
    }

    @Test func anAwaitedItemRaisesTheFrontPastTheFence() async throws {
        let work = BackgroundWork(label: "test.sequence-fence")
        let sequence = work.sequence("test.fenced")
        let log = Log()
        work.beginBestEffortFence()
        sequence.post(.bestEffort) { log.add("save") }
        // The fence holds the posted save; the read behind it needs it to run, so it lifts it for the save.
        let read = try await Task(priority: .high) {
            try await sequence.run(.userBlocking) { () throws -> Int in
                log.add("read")
                return 7
            }
        }.value
        #expect(read == 7)
        #expect(log.entries == ["save", "read"])
        work.endBestEffortFence()
    }

    @Test func aRaisedFrontLeavesItsFullLevelAtTheHigherQoS() async throws {
        let ranAt = Box<[WorkPriority]>([])
        let work = BackgroundWork(label: "test.sequence-raise", onRan: { _, priority, _, _ in ranAt.withLock { $0.append(priority) } })
        let sequence = work.sequence("test.raised")
        let started = Signal()
        let release = DispatchSemaphore(value: 0)
        // Every best-effort slot is held.
        for _ in 0..<FilesLaneWidths.standard.bestEffort {
            work.post(.bestEffort, mayBlock: .files) {
                started.signal()
                release.wait()
            }
        }
        await started.wait(FilesLaneWidths.standard.bestEffort)
        let saveQoS = Box<qos_class_t?>(nil)
        sequence.post(.bestEffort) { saveQoS.withLock { $0 = qos_class_self() } }
        // The awaited read moves the queued save to user-blocking; else both wait for the held slots.
        let read = try await Task(priority: .high) {
            try await sequence.run(.userBlocking) { () throws -> Bool in saveQoS.withLock { $0 != nil } }
        }.value
        #expect(read, "the read ran before the save")
        #expect(saveQoS.withLock { $0 } == QOS_CLASS_USER_INITIATED)
        // The save reported its run (before the read could start) at the level it ran at, not the one it was posted at.
        #expect(ranAt.withLock { $0.first } == .userBlocking)
        for _ in 0..<FilesLaneWidths.standard.bestEffort { release.signal() }
    }

    /// An awaited item at the front's own level changes only whether the front is awaited: the front keeps its
    /// place before the files work posted after it, so the item someone waits for does not wait behind that work.
    @Test func anAwaitedItemAtTheFrontsLevelKeepsTheFrontAheadOfLaterWork() async throws {
        let queued = Signal(), started = Signal()
        // One user-visible slot, so the start order of the queued items is the order they leave the queue in.
        let work = BackgroundWork(filesWidths: .serial, label: "test.sequence-keep-place", onQueued: { lane, level in
            if lane == .files && level == .userVisible { queued.signal() }
        })
        let sequence = work.sequence("test.keep-place")
        let log = Log()
        let release = DispatchSemaphore(value: 0)
        work.post(.userVisible, mayBlock: .files) {
            started.signal()
            release.wait()
        }
        await started.wait(1)
        sequence.post(.userVisible) { log.add("front") }
        work.post(.userVisible, mayBlock: .files) { log.add("unrelated") }
        await queued.wait(2)
        let read = Task(priority: .medium) { try await sequence.run(.userVisible) { log.add("read") } }
        await queued.wait(1)
        release.signal()
        try await read.value
        #expect(log.entries == ["front", "unrelated", "read"])
    }

    @Test func aCancelledWaitingItemNeverRunsAndTheRestKeepTheirOrder() async throws {
        let queued = Signal(), started = Signal()
        let work = BackgroundWork(label: "test.sequence-cancel", onQueued: { _, _ in queued.signal() })
        let sequence = work.sequence("test.cancel")
        let log = Log()
        let release = DispatchSemaphore(value: 0)
        sequence.post(.userVisible) {
            started.signal()
            release.wait()
            log.add("first")
        }
        await started.wait(1)
        let waiter = Task(priority: .medium) {
            try await sequence.run(.userVisible) { log.add("cancelled") }
        }
        // Cancel once it waits in the sequence, so the cancel takes it out of the queue (not the check at the call).
        await queued.wait(1)
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        release.signal()
        try await sequence.run(.userVisible) { log.add("last") }
        #expect(log.entries == ["first", "last"])
    }

    @Test func shutdownDropsASkipItemAndStillRunsTheSaveBehindIt() async {
        let work = BackgroundWork(label: "test.sequence-shutdown")
        let sequence = work.sequence("test.shutdown")
        let log = Log()
        let started = Signal()
        let release = DispatchSemaphore(value: 0)
        sequence.post(.userBlocking, shutdown: .continueOnShutdown) {
            started.signal()
            release.wait()
            log.add("running")
        }
        await started.wait(1)
        sequence.post(.userBlocking, shutdown: .skipOnShutdown, abandoned: { log.add("dropped") }) { log.add("skip") }
        sequence.post(.userBlocking, shutdown: .blockShutdown) { log.add("save") }
        work.beginShutdown()
        release.signal()
        await work.shutdown()
        #expect(log.entries == ["running", "dropped", "save"])
    }
}
