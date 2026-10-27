import CmuxNextCompat
@testable import CmuxNextWakeups
import Darwin
import Dispatch
import Testing

/// Yieldable CPU jobs (plans/cmux-next/chrome-parity/p02-threads.md, task 125): `work.job` runs chunks on the cpu
/// lane and stops between two of them when ``JobDelegate/shouldYield`` says higher work waits for its slot; its rest
/// runs later from the state it left. Chrome's `base::PostJob` and `JobDelegate::ShouldYield` (base/task/post_job.h,
/// base/task/thread_pool/thread_group.cc).
///
/// Each lane here has one cpu slot unless a test says otherwise, so a waiting item can start only when the job yields.
@Suite(.timeLimit(.minutes(1))) struct LaneYieldTests {
    /// Lane bodies (synchronous) report; the async test awaits the reports.
    struct Signal: Sendable {
        private let stream: AsyncStream<Void>
        private let continuation: AsyncStream<Void>.Continuation

        init() { (stream, continuation) = AsyncStream.makeStream(of: Void.self) }

        func send() { continuation.yield() }

        func wait(_ count: Int) async {
            var left = count
            guard left > 0 else { return }
            for await _ in stream {
                left -= 1
                if left == 0 { return }
            }
        }
    }

    /// The order lane bodies and the test recorded their steps in.
    final class RunOrder: Sendable {
        private let names = Mutex<[String]>([])

        func record(_ name: String) { names.withLock { $0.append(name) } }

        var order: [String] { names.withLock { $0 } }
    }

    /// Nanosecond stamps by name (`CLOCK_UPTIME_RAW`).
    final class Stamps: Sendable {
        private let stamps = Mutex<[String: UInt64]>([:])

        func mark(_ name: String) { stamps.withLock { $0[name] = Self.now() } }

        subscript(name: String) -> UInt64? { stamps.withLock { $0[name] } }

        static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
    }

    private static func work(_ label: String, cpuWidth: Int = 1, queued: Signal = Signal()) -> BackgroundWork {
        BackgroundWork(cpuWidth: cpuWidth, label: label, onQueued: { lane, _ in if lane == .cpu { queued.send() } },
                       uptimeNanos: nil, taskHooks: .none)
    }

    /// A job of `chunks` chunks that records each one ("<name> <n>"), stops before its second chunk until `gate` is
    /// signalled (after `held` is sent), records what ``JobDelegate/shouldYield`` said then, and yields when asked.
    private static func gatedJob(_ work: BackgroundWork, _ priority: WorkPriority, name: String, chunks: Int,
                                 shutdown: ShutdownBehavior = .skipOnShutdown, runs: RunOrder, held: Signal,
                                 gate: DispatchSemaphore) -> Task<Int, any Error> {
        Task(priority: priority.taskPriority) {
            try await work.job(priority, shutdown: shutdown, state: 0) { done, delegate in
                repeat {
                    done += 1
                    runs.record("\(name) \(done)")
                    if done == chunks { return .finished(done) }
                    if done == 1 {
                        held.send()
                        gate.wait()
                        runs.record("\(name) asked \(delegate.shouldYield)")
                    }
                } while !delegate.shouldYield
                return .yielded
            }
        }
    }

    @Test func aUserBlockingItemQueuedAt12msStartsWithin6msBehindA100x5msBestEffortJob() async throws {
        struct Progress: Sendable {
            var chunk = 0
            var start: UInt64 = 0
            var posted = false
        }
        let stamps = Stamps()
        let work = Self.work("test.yield-latency")
        let chunk: UInt64 = 5_000_000
        let job = Task(priority: .utility) {
            try await work.job(.bestEffort, state: Progress()) { progress, delegate in
                if progress.start == 0 { progress.start = Stamps.now() }
                repeat {
                    let chunkStart = Stamps.now()
                    while Stamps.now() - chunkStart < chunk {
                        guard !progress.posted, Stamps.now() - progress.start >= 12_000_000 else { continue }
                        progress.posted = true
                        stamps.mark("queued")
                        work.post(.userBlocking, mayBlock: .cpu) { stamps.mark("started") }
                    }
                    progress.chunk += 1
                    if progress.chunk == 100 { return .finished(progress.chunk) }
                } while !delegate.shouldYield
                return .yielded
            }
        }
        #expect(try await job.value == 100)
        let queued = try #require(stamps["queued"]), started = try #require(stamps["started"])
        #expect(started - queued < 6_000_000, "waited \(Double(started - queued) / 1e6) ms behind one 5 ms chunk")
    }

    @Test func theRestRunsAfterTheHigherItemFromTheStateItLeft() async throws {
        let queued = Signal(), held = Signal(), runs = RunOrder(), gate = DispatchSemaphore(value: 0)
        let work = Self.work("test.yield-rest", queued: queued)
        let job = Self.gatedJob(work, .bestEffort, name: "job", chunks: 4, runs: runs, held: held, gate: gate)
        await held.wait(1)
        let blocking = Task { try await work.run(.userBlocking, mayBlock: .cpu) { runs.record("blocking") } }
        await queued.wait(1)
        gate.signal()
        try await blocking.value
        #expect(try await job.value == 4)
        #expect(runs.order == ["job 1", "job asked true", "blocking", "job 2", "job 3", "job 4"])
    }

    /// The rest goes back by id (Chrome's `JobTaskSource::GetSortKey` keeps the job's queue time): before a
    /// best-effort item posted after the job started, not at the end of the best-effort list.
    @Test func theRestGoesBeforeSameLevelItemsPostedAfterTheJobStarted() async throws {
        let queued = Signal(), held = Signal(), runs = RunOrder(), gate = DispatchSemaphore(value: 0), ran = Signal()
        let work = Self.work("test.yield-order", queued: queued)
        let job = Self.gatedJob(work, .bestEffort, name: "job", chunks: 3, runs: runs, held: held, gate: gate)
        await held.wait(1)
        work.post(.bestEffort, mayBlock: .cpu) {
            runs.record("later")
            ran.send()
        }
        await queued.wait(1)
        let blocking = Task { try await work.run(.userBlocking, mayBlock: .cpu) { runs.record("blocking") } }
        await queued.wait(1)
        gate.signal()
        try await blocking.value
        #expect(try await job.value == 3)
        await ran.wait(1)
        #expect(runs.order == ["job 1", "job asked true", "blocking", "job 2", "job 3", "later"])
    }

    /// A caller cancelled while the yielded rest waits takes the rest out of the queue: no later chunk runs and the
    /// lane goes on with the next item.
    @Test func aCallerCancelledWhileTheRestWaitsDropsTheRest() async throws {
        let queued = Signal(), held = Signal(), runs = RunOrder(), gate = DispatchSemaphore(value: 0)
        let started = Signal(), release = DispatchSemaphore(value: 0)
        let work = Self.work("test.yield-cancel-queued", queued: queued)
        let job = Self.gatedJob(work, .bestEffort, name: "job", chunks: 5, runs: runs, held: held, gate: gate)
        await held.wait(1)
        work.post(.userBlocking, mayBlock: .cpu) {
            runs.record("blocking")
            started.send()
            release.wait()
        }
        await queued.wait(1)
        gate.signal()
        // The job yielded and its rest waits behind the held user-blocking item.
        await started.wait(1)
        job.cancel()
        await #expect(throws: CancellationError.self) { try await job.value }
        release.signal()
        #expect(try await work.run(.userVisible, mayBlock: .cpu) { () throws -> Int in 7 } == 7)
        #expect(runs.order == ["job 1", "job asked true", "blocking"])
    }

    @Test func aJobNeverYieldsToBestEffortWork() async throws {
        let queued = Signal(), held = Signal(), runs = RunOrder(), gate = DispatchSemaphore(value: 0), ran = Signal()
        let work = Self.work("test.yield-best-effort", queued: queued)
        let job = Self.gatedJob(work, .idle, name: "job", chunks: 3, runs: runs, held: held, gate: gate)
        await held.wait(1)
        work.post(.bestEffort, mayBlock: .cpu) {
            runs.record("best effort")
            ran.send()
        }
        await queued.wait(1)
        gate.signal()
        #expect(try await job.value == 3)
        await ran.wait(1)
        #expect(runs.order == ["job 1", "job asked false", "job 2", "job 3", "best effort"])
    }

    @Test func oneWaitingItemAsksOnlyTheLowestJob() async throws {
        let queued = Signal(), held = Signal(), runs = RunOrder(), gate = DispatchSemaphore(value: 0)
        let work = Self.work("test.yield-one", cpuWidth: 2, queued: queued)
        let visible = Self.gatedJob(work, .userVisible, name: "visible", chunks: 2, runs: runs, held: held, gate: gate)
        let idle = Self.gatedJob(work, .idle, name: "idle", chunks: 2, runs: runs, held: held, gate: gate)
        await held.wait(2)
        let blocking = Task { try await work.run(.userBlocking, mayBlock: .cpu) { runs.record("blocking") } }
        await queued.wait(1)
        gate.signal()
        gate.signal()
        try await blocking.value
        #expect(try await visible.value == 2)
        #expect(try await idle.value == 2)
        #expect(runs.order.contains("visible asked false"))
        #expect(runs.order.contains("idle asked true"))
    }

    @Test func aCancelledCallerStopsTheJobAtItsNextChunk() async throws {
        let held = Signal(), runs = RunOrder(), gate = DispatchSemaphore(value: 0)
        let work = Self.work("test.yield-cancel")
        let job = Self.gatedJob(work, .bestEffort, name: "job", chunks: 5, runs: runs, held: held, gate: gate)
        await held.wait(1)
        job.cancel()
        gate.signal()
        await #expect(throws: CancellationError.self) { try await job.value }
        #expect(runs.order == ["job 1", "job asked true"])
        // The lane is free again: nothing of the job is left queued in front of later work.
        #expect(try await work.run(.userVisible, mayBlock: .cpu) { () throws -> Int in 7 } == 7)
    }

    @Test func shutdownDropsTheRestOfASkipJob() async throws {
        let held = Signal(), runs = RunOrder(), gate = DispatchSemaphore(value: 0)
        let work = Self.work("test.yield-skip")
        let job = Self.gatedJob(work, .bestEffort, name: "job", chunks: 5, runs: runs, held: held, gate: gate)
        await held.wait(1)
        work.beginShutdown()
        gate.signal()
        await #expect(throws: CancellationError.self) { try await job.value }
        #expect(runs.order == ["job 1", "job asked true"])
        await work.shutdown()
    }

    /// A continue-on-shutdown job whose rest is queued when shutdown starts: shutdown drops the rest, as it drops
    /// every queued item that is not block-shutdown (Chrome's `TaskTracker::BeforeRunTask`).
    @Test func shutdownDropsTheQueuedRestOfAContinueJob() async throws {
        let queued = Signal(), held = Signal(), runs = RunOrder(), gate = DispatchSemaphore(value: 0)
        let started = Signal(), release = DispatchSemaphore(value: 0)
        let work = Self.work("test.yield-continue-queued", queued: queued)
        let job = Self.gatedJob(work, .bestEffort, name: "job", chunks: 5, shutdown: .continueOnShutdown, runs: runs,
                                held: held, gate: gate)
        await held.wait(1)
        work.post(.userBlocking, mayBlock: .cpu) {
            runs.record("blocking")
            started.send()
            release.wait()
        }
        await queued.wait(1)
        gate.signal()
        await started.wait(1)
        work.beginShutdown()
        await #expect(throws: CancellationError.self) { try await job.value }
        release.signal()
        await work.shutdown()
        #expect(runs.order == ["job 1", "job asked true", "blocking"])
    }

    /// A continue-on-shutdown job that yields after shutdown started: its rest is refused, as submit refuses a
    /// continue-on-shutdown item then, so the outcome does not depend on whether the rest was queued or running.
    @Test func shutdownRefusesTheRestOfAContinueJobThatYieldsLater() async throws {
        let queued = Signal(), held = Signal(), runs = RunOrder(), gate = DispatchSemaphore(value: 0)
        let work = Self.work("test.yield-continue-running", queued: queued)
        let job = Self.gatedJob(work, .bestEffort, name: "job", chunks: 5, shutdown: .continueOnShutdown, runs: runs,
                                held: held, gate: gate)
        await held.wait(1)
        // The waiting user-blocking item asks the job to yield; shutdown then drops that item.
        let blocking = Task { try await work.run(.userBlocking, mayBlock: .cpu) { runs.record("blocking") } }
        await queued.wait(1)
        work.beginShutdown()
        await #expect(throws: CancellationError.self) { try await blocking.value }
        gate.signal()
        await #expect(throws: CancellationError.self) { try await job.value }
        await work.shutdown()
        #expect(runs.order == ["job 1", "job asked true"])
    }

    /// Shutdown does not ask a running continue-on-shutdown run to yield, so a run that is not asked ends the job.
    @Test func aContinueJobNobodyAsksEndsInTheRunShutdownFound() async throws {
        let held = Signal(), runs = RunOrder(), gate = DispatchSemaphore(value: 0)
        let work = Self.work("test.yield-continue-unasked")
        let job = Self.gatedJob(work, .bestEffort, name: "job", chunks: 3, shutdown: .continueOnShutdown, runs: runs,
                                held: held, gate: gate)
        await held.wait(1)
        work.beginShutdown()
        gate.signal()
        #expect(try await job.value == 3)
        await work.shutdown()
        #expect(runs.order == ["job 1", "job asked false", "job 2", "job 3"])
    }

    @Test func aBlockShutdownJobThatYieldsStillHoldsShutdownUntilItsEnd() async throws {
        let queued = Signal(), held = Signal(), runs = RunOrder(), gate = DispatchSemaphore(value: 0)
        let work = Self.work("test.yield-block", queued: queued)
        let job = Self.gatedJob(work, .bestEffort, name: "job", chunks: 3, shutdown: .blockShutdown, runs: runs,
                                held: held, gate: gate)
        await held.wait(1)
        // A waiting user-blocking item asks the job to yield; shutdown then drops that item, not the job.
        let blocking = Task { try await work.run(.userBlocking, mayBlock: .cpu) { runs.record("blocking") } }
        await queued.wait(1)
        work.beginShutdown()
        await #expect(throws: CancellationError.self) { try await blocking.value }
        let drained = Task {
            await work.shutdown()
            runs.record("drained")
        }
        gate.signal()
        #expect(try await job.value == 3)
        await drained.value
        #expect(runs.order == ["job 1", "job asked true", "job 2", "job 3", "drained"])
    }

    /// The acceptance bound (< 10 ns) holds only in an optimized build:
    /// `swift test -c release -Xswiftc -enable-testing --filter LaneYieldTests/shouldYieldCostsUnder10ns`.
    /// A Debug run checks only a loose bound and is not the acceptance.
    @Test func shouldYieldCostsUnder10ns() {
        let delegate = JobDelegate()
        let reads = 1_000_000
        var asked = 0
        let start = Stamps.now()
        for _ in 0..<reads where delegate.shouldYield { asked += 1 }
        let perRead = Double(Stamps.now() - start) / Double(reads)
        print("JobDelegate.shouldYield: \(perRead) ns per read")
        #expect(asked == 0)
        #if DEBUG
        #expect(perRead < 200, "Debug build: a loose bound, not the acceptance (run it with -c release)")
        #else
        #expect(perRead < 10, "one relaxed atomic load")
        #endif
    }
}
