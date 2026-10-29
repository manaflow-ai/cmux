import CmuxNextCompat
import CmuxNextSignposts
@testable import CmuxNextTrace
@testable import CmuxNextWakeups
import Dispatch
import Testing

/// Each lane item posted while the trace's `task` category records runs inside one `task.run` slice with its lane,
/// priority and queue wait; an item posted while it is off writes nothing (plans/cmux-next/trace.md
/// "Blocking calls and lane jobs"). Every lane here has one slot, so its items run one after another.
@Suite(.timeLimit(.minutes(1))) struct LaneJobTraceTests {
    /// The `task.run` records a test runtime writes, and a signal per record.
    final class RunRecords: Sendable {
        private let records = Mutex<[TraceRuntime.StubRecord]>([])
        private let stream: AsyncStream<Void>
        private let continuation: AsyncStream<Void>.Continuation

        init() { (stream, continuation) = AsyncStream.makeStream(of: Void.self) }

        /// A runtime whose `task.run` records land here; its clock reads `uptime`.
        func runtime(uptime: @escaping @Sendable () -> UInt64) -> TraceRuntime {
            let clock = TraceClock(reader: TraceClock.Reader(uptimeNanos: uptime, continuousNow: { ContinuousClock.now }))
            return TraceRuntime(role: .app, clock: clock, stubRecorder: { [self] record in
                guard record.name == SignpostName.taskRun.rawValue else { return }
                records.withLock { $0.append(record) }
                continuation.yield()
            })
        }

        var all: [TraceRuntime.StubRecord] { records.withLock { $0 } }

        func wait(_ count: Int) async {
            var left = count
            guard left > 0 else { return }
            for await _ in stream {
                left -= 1
                if left == 0 { return }
            }
        }
    }

    /// A clock the test moves, which counts its reads.
    final class TestUptime: Sendable {
        private let state = Mutex<(nanos: UInt64, reads: Int)>((1_000_000, 0))
        func read() -> UInt64 {
            state.withLock { state in
                state.reads += 1
                return state.nanos
            }
        }
        func advance(_ by: UInt64) { state.withLock { $0.nanos += by } }
        var reads: Int { state.withLock { $0.reads } }
    }

    private static func job(_ id: UInt64, _ body: @escaping @Sendable () -> Void = {}) -> LaneJob {
        LaneJob(id: id, shutdown: .skipOnShutdown, work: { _ in body() }, abandoned: {}, done: {})
    }

    @Test func anItemPostedWhileTracingRunsInOneSliceAndOneAfterTracingStopsWritesNone() async {
        let records = RunRecords(), uptime = TestUptime()
        let runtime = records.runtime(uptime: { uptime.read() })
        let lane = LaneScheduler(label: "test.trace-lane", policy: .shared(width: 1), mayBlock: true, lane: .files,
                                 trace: runtime)

        _ = lane.submit(Self.job(1), at: .userVisible, posted: true, unless: { false })  // off: no slice
        runtime.setCategories(.task)
        _ = lane.submit(Self.job(2), at: .bestEffort, posted: true, unless: { false })
        await records.wait(2)

        let all = records.all
        #expect(all.map(\.phase) == [.begin, .end])
        #expect(all.first?.arg0 == UInt64(BlockingLane.files.rawValue) << 8 | UInt64(WorkPriority.bestEffort.rawValue))
        #expect(all.first?.categoryBit == TraceCategories.taskBit)
    }

    /// The begin's arg1 is the time from the post to the start, in microseconds, on the trace clock.
    @Test func theBeginCarriesTheQueueWait() async {
        let records = RunRecords(), uptime = TestUptime()
        let runtime = records.runtime(uptime: { uptime.read() })
        runtime.setCategories(.task)
        let lane = LaneScheduler(label: "test.trace-wait", policy: .shared(width: 1), mayBlock: true, trace: runtime)
        let release = DispatchSemaphore(value: 0)
        let (started, start) = AsyncStream.makeStream(of: Void.self)

        _ = lane.submit(Self.job(1) {
            start.yield()
            release.wait()  // a lane that may block: it holds the one slot
        }, at: .userVisible, posted: true, unless: { false })
        var startedIterator = started.makeAsyncIterator()
        _ = await startedIterator.next()
        _ = lane.submit(Self.job(2), at: .userVisible, posted: true, unless: { false })
        uptime.advance(3_000_000)
        release.signal()
        await records.wait(4)

        let begins = records.all.filter { $0.phase == .begin }
        #expect(begins.map(\.arg1) == [0, 3_000])
        #expect(begins.map(\.arg0) == [0xFF << 8 | UInt64(WorkPriority.userVisible.rawValue),
                                       0xFF << 8 | UInt64(WorkPriority.userVisible.rawValue)])
    }

    /// A sequence item's queue wait counts from its post to the sequence, so it includes the time it waited behind
    /// the item in front of it, not only the time from the hand-off to the lane.
    @Test func aSequenceItemsWaitIncludesTheTimeBehindTheItemInFront() async {
        let records = RunRecords(), uptime = TestUptime()
        let runtime = records.runtime(uptime: { uptime.read() })
        runtime.setCategories(.task)
        let work = BackgroundWork(cpuWidth: 1, label: "test.trace-sequence", onQueued: { _, _ in }, uptimeNanos: nil,
                                  taskHooks: .none, trace: runtime)
        let sequence = work.sequence("test.trace-sequence.saves")
        let release = DispatchSemaphore(value: 0)
        let (started, start) = AsyncStream.makeStream(of: Void.self)

        sequence.post(.userVisible) {
            start.yield()
            release.wait()  // the files lane may block: the second item waits behind this one in the sequence
        }
        var startedIterator = started.makeAsyncIterator()
        _ = await startedIterator.next()
        sequence.post(.userVisible) {}
        uptime.advance(3_000_000)
        release.signal()
        await records.wait(4)

        let begins = records.all.filter { $0.phase == .begin }
        #expect(begins.map(\.arg1) == [0, 3_000])
        #expect(begins.map(\.arg0) == [UInt64(BlockingLane.files.rawValue) << 8 | UInt64(WorkPriority.userVisible.rawValue),
                                       UInt64(BlockingLane.files.rawValue) << 8 | UInt64(WorkPriority.userVisible.rawValue)])
    }

    /// A lane whose trace never records reads no trace clock for its items.
    @Test func anItemWithTracingOffReadsNoTraceClock() async {
        let records = RunRecords(), uptime = TestUptime()
        let runtime = records.runtime(uptime: { uptime.read() })
        let lane = LaneScheduler(label: "test.trace-off", policy: .shared(width: 1), mayBlock: true, trace: runtime)
        let (ran, run) = AsyncStream.makeStream(of: Void.self)

        _ = lane.submit(Self.job(1) { run.yield() }, at: .userVisible, posted: true, unless: { false })
        var ranIterator = ran.makeAsyncIterator()
        _ = await ranIterator.next()

        #expect(uptime.reads == 0)
        #expect(records.all.isEmpty)
    }
}
