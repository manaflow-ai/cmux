import CmuxNextCompat
import CmuxNextSignposts
import CmuxNextTrace
@testable import CmuxNextWakeups
import Testing

/// TracedTask (plans/cmux-next/chrome-parity/p09-observability.md, task 124): a detached task's post writes a
/// `task.post` flow-out named by its `#fileID` and `#line`, and its run a `task.run` async slice on the pool lane
/// with its priority and queue wait, with the flow-in right after the slice's begin. Chrome's `PostTask(FROM_HERE)`
/// and `TaskAnnotator` (base/task/common/task_annotator.cc).
@Suite(.timeLimit(.minutes(1))) struct TracedTaskTests {
    /// The decoded task records of one ring.
    struct TaskRecords {
        let image: TraceRing.Image

        init(_ ring: TraceRing) throws {
            image = try #require(ring.decodedImage())
        }

        func named(_ name: SignpostName, _ phase: TraceRecord.Phase) -> [TraceRecord] {
            image.records.filter { $0.name == name.rawValue && $0.phase == phase }
        }

        /// The site a record's `arg0` names: its file's text and its line.
        func site(_ record: TraceRecord) -> (file: String?, line: UInt64) {
            (image.name(UInt16(truncatingIfNeeded: record.arg0)), record.arg0 >> 16 & 0xFFFF_FFFF)
        }

        /// The record `record`'s thread wrote just before it.
        func previous(_ record: TraceRecord) -> TraceRecord? {
            let thread = image.records.filter { $0.threadIndex == record.threadIndex }
            guard let index = thread.firstIndex(of: record), index > 0 else { return nil }
            return thread[index - 1]
        }
    }

    /// A clock the test moves.
    final class Uptime: Sendable {
        private let nanos = Mutex<UInt64>(1_000_000)
        func read() -> UInt64 { nanos.withLock { $0 } }
        func advance(_ by: UInt64) { nanos.withLock { $0 += by } }
    }

    /// A runtime writing into `ring` with only `categories` on.
    static func runtime(_ ring: TraceRing, _ categories: [SignpostCategory], clock: TraceClock = TraceClock()) -> TraceRuntime {
        let runtime = TraceRuntime(role: .app, clock: clock)
        _ = runtime.attach(ring)
        runtime.setCategoryMask(categories.reduce(UInt64(0)) { $0 | 1 << UInt64($1.traceBit) })
        return runtime
    }

    /// The `task.run` AB arg0 of a run on the pool at `priority` that waited `waitMicros`.
    static func runArg0(_ priority: WorkPriority, waitMicros: UInt64) -> UInt64 {
        waitMicros << 16 | UInt64(TaskTrace.Lane.pool.rawValue) << 8 | UInt64(priority.rawValue)
    }

    @Test func threeTasksDecodeAsThreeFlowsWithTheirPostSites() async throws {
        let ring = TraceRing(records: 4096, role: .app)
        let tasks = TracedTask(trace: TaskTrace(runtime: Self.runtime(ring, [.task])))
        let first = tasks.detached(priority: .userBlocking) { 1 }
        let firstLine = UInt64(#line - 1)
        // A suspension inside: the slice may end on another thread than it began on.
        let second = tasks.detached(priority: .userVisible) { () async -> Int in await Task.yield(); return 2 }
        let secondLine = UInt64(#line - 1)
        let third = tasks.detached(priority: .bestEffort) { 3 }
        let thirdLine = UInt64(#line - 1)
        #expect(await [first.value, second.value, third.value] == [1, 2, 3])

        let records = try TaskRecords(ring)
        let posts = records.named(.taskPost, .flowOut)
        let arrivals = records.named(.taskRun, .flowIn)
        let begins = records.named(.taskRun, .asyncBegin)
        let ends = records.named(.taskRun, .asyncEnd)
        try #require(posts.count == 3)
        try #require(arrivals.count == 3)
        #expect(records.named(.taskRun, .begin).isEmpty, "a detached task's run is an async slice, not a thread slice")
        #expect(Set(posts.map(\.arg1)).count == 3, "each post has its own flow")
        #expect(Set(posts.map(\.arg1)) == Set(arrivals.map(\.arg1)), "each flow ends at a run")
        #expect(Set(begins.map(\.arg1)) == Set(posts.map(\.arg1)), "each slice is keyed by its flow")
        #expect(Set(ends.map(\.arg1)) == Set(posts.map(\.arg1)), "each slice ends")
        #expect(begins.allSatisfy { $0.flags & TraceRuntime.RecordFlags.asyncID.rawValue != 0 })
        #expect(ends.allSatisfy { $0.flags & TraceRuntime.RecordFlags.asyncID.rawValue != 0 })
        #expect(posts.allSatisfy { records.site($0).file == "CmuxNextWakeupsTests/TracedTaskTests.swift" })
        #expect(Set(posts.map { records.site($0).line }) == [firstLine, secondLine, thirdLine])

        let priorities: [UInt64: WorkPriority] = [firstLine: .userBlocking, secondLine: .userVisible, thirdLine: .bestEffort]
        for post in posts {
            let arrival = try #require(arrivals.first { $0.arg1 == post.arg1 })
            #expect(arrival.arg0 == post.arg0, "the run names its post's site")
            #expect(arrival.timestamp >= post.timestamp)
            let begin = try #require(records.previous(arrival), "the flow-in follows its slice's begin")
            #expect(begin.name == SignpostName.taskRun.rawValue && begin.phase == .asyncBegin)
            #expect(begin.arg1 == post.arg1)
            let priority = try #require(priorities[records.site(post).line])
            #expect(begin.arg0 & 0xFFFF == Self.runArg0(priority, waitMicros: 0), "the pool lane and the post's priority")
            #expect(begin.arg0 >> 16 != TaskTrace.unknownAsyncWait, "a traced post gives its run a queue wait")
            let end = try #require(ends.first { $0.arg1 == post.arg1 })
            #expect(end.timestamp >= begin.timestamp)
        }
    }

    @Test func aThrowingTaskIsTracedAndRethrows() async throws {
        struct Refused: Error {}
        let ring = TraceRing(records: 4096, role: .app)
        let tasks = TracedTask(trace: TaskTrace(runtime: Self.runtime(ring, [.task])))
        let task = tasks.detached(priority: .userVisible) { () async throws -> Int in throw Refused() }
        await #expect(throws: Refused.self) { try await task.value }

        let records = try TaskRecords(ring)
        let flows = records.named(.taskPost, .flowOut).map(\.arg1)
        #expect(flows.count == 1)
        #expect(records.named(.taskRun, .asyncBegin).map(\.arg1) == flows)
        #expect(records.named(.taskRun, .asyncEnd).map(\.arg1) == flows, "a throw still ends the slice")
    }

    @Test func theTaskRunsAtThePriorityItNames() async {
        let ring = TraceRing(records: 4096, role: .app)
        let traced = TracedTask(trace: TaskTrace(runtime: Self.runtime(ring, [.task])))
        let untraced = TracedTask(trace: TaskTrace(runtime: Self.runtime(ring, [])))
        // The highest level only: awaiting a lower one's value from the test may raise it before it reads.
        #expect(await traced.detached(priority: .userBlocking) { Task.currentPriority }.value == .high)
        #expect(await untraced.detached(priority: .userBlocking) { Task.currentPriority }.value == .high)
    }

    @Test func withTheTaskCategoryOffNothingIsWritten() async {
        let ring = TraceRing(records: 4096, role: .app)
        let tasks = TracedTask(trace: TaskTrace(runtime: Self.runtime(ring, [.action, .control])))
        #expect(await tasks.detached(priority: .bestEffort) { 7 }.value == 7)
        #expect(ring.records().isEmpty)
    }

    @Test func theQueueWaitIsTheTimeFromThePostToTheRun() throws {
        let uptime = Uptime()
        let clock = TraceClock(reader: TraceClock.Reader(uptimeNanos: { uptime.read() }, continuousNow: { ContinuousClock.now }))
        let ring = TraceRing(records: 4096, role: .app)
        let ticket = TaskTrace(runtime: Self.runtime(ring, [.task], clock: clock)).post(fileID: #fileID, line: #line, lane: .pool)
        uptime.advance(2_500_000)
        ticket.beginAsyncRun(priority: TracedTask.code(.userVisible)).end()

        let records = try TaskRecords(ring)
        let begins = records.named(.taskRun, .asyncBegin)
        #expect(begins.map(\.arg0) == [Self.runArg0(.userVisible, waitMicros: 2_500)])
        #expect(records.named(.taskRun, .asyncEnd).count == 1)
    }

    /// A task posted before the recording started still gets its `task.run` slice: the run reads the category
    /// again, as Chrome's `TaskAnnotator::RunTask` does. The run is the one every ``TracedTask`` runs through.
    @Test func aTaskPostedBeforeTheRecordingStartedRunsInASliceWithNoFlowAndAnUnknownWait() async throws {
        let ring = TraceRing(records: 4096, role: .app)
        let runtime = Self.runtime(ring, [])
        let ticket = TaskTrace(runtime: runtime).post(fileID: #fileID, line: #line, lane: .pool)
        #expect(!ticket.isTraced)
        runtime.setCategoryMask(1 << UInt64(SignpostCategory.task.traceBit))
        let value = await TracedTask.run(ticket, priority: TracedTask.code(.bestEffort)) { 5 }
        #expect(value == 5)

        let records = try TaskRecords(ring)
        #expect(records.named(.taskPost, .flowOut).isEmpty)
        #expect(records.named(.taskRun, .flowIn).isEmpty)
        let begins = records.named(.taskRun, .asyncBegin)
        #expect(begins.map(\.arg0) == [Self.runArg0(.bestEffort, waitMicros: TaskTrace.unknownAsyncWait)])
        #expect(records.named(.taskRun, .asyncEnd).map(\.arg1) == begins.map(\.arg1))
    }

    @Test func postersOnOneRuntimeShareTheirSiteFileName() throws {
        let ring = TraceRing(records: 4096, role: .app)
        let runtime = Self.runtime(ring, [.task])
        _ = TaskTrace(runtime: runtime).post(fileID: #fileID, line: #line, lane: .pool)
        _ = TaskTrace(runtime: runtime).post(fileID: #fileID, line: #line, lane: .files)
        #expect(runtime.siteFile(#fileID) === runtime.siteFile(#fileID))

        let posts = try TaskRecords(ring).named(.taskPost, .flowOut)
        try #require(posts.count == 2)
        #expect(Set(posts.map { UInt16(truncatingIfNeeded: $0.arg0) }).count == 1, "one name-table entry per file")
    }
}
