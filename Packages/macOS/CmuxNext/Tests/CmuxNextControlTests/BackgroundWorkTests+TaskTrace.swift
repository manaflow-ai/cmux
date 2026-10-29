import CmuxNextSignposts
import CmuxNextTrace
import CmuxNextWakeups
import Testing

/// Task tracing (p09-observability task 042): every lane item's post writes a `task.post` flow-out named by its
/// `#fileID` and `#line`, and its run the matching flow-in inside the lane's one `task.run` slice, with its lane,
/// its priority and its queue wait. Chrome's `TaskAnnotator` (base/task/common/task_annotator.cc).
extension BackgroundWorkTests {
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

    /// A runtime writing into `ring` with only `categories` on.
    static func traceRuntime(_ ring: TraceRing, _ categories: [SignpostCategory]) -> TraceRuntime {
        let runtime = TraceRuntime(role: .app)
        _ = runtime.attach(ring)
        runtime.setCategoryMask(categories.reduce(UInt64(0)) { $0 | 1 << UInt64($1.traceBit) })
        return runtime
    }

    @Test func threePostsDecodeAsThreeFlowPairsWithTheirSites() async throws {
        let ring = TraceRing(records: 4096, role: .app)
        let work = BackgroundWork(label: "test.task-trace", trace: Self.traceRuntime(ring, [.task]))
        let started = Started()
        work.post(.bestEffort, mayBlock: .files, shutdown: .blockShutdown) { started.signal() }
        let filesLine = UInt64(#line - 1)
        work.post(.userVisible, mayBlock: .cpu, shutdown: .blockShutdown) { started.signal() }
        let cpuLine = UInt64(#line - 1)
        work.post(.userBlocking, mayBlock: .system, shutdown: .blockShutdown) { started.signal() }
        let systemLine = UInt64(#line - 1)
        // Every item started at its own priority; shutdown returns once each ran to its end.
        await started.wait(3)
        await work.shutdown()

        let records = try TaskRecords(ring)
        let posts = records.named(.taskPost, .flowOut)
        let arrivals = records.named(.taskRun, .flowIn)
        try #require(posts.count == 3)
        try #require(arrivals.count == 3)
        #expect(records.named(.taskRun, .begin).count == 3, "one slice per item: the lane's")
        #expect(records.named(.taskRun, .end).count == 3)
        #expect(Set(posts.map(\.arg1)).count == 3, "each post has its own flow")
        #expect(Set(posts.map(\.arg1)) == Set(arrivals.map(\.arg1)), "each flow ends at a run")
        // A ring name entry holds at most 55 UTF-8 bytes (trace.md "Name table"); this #fileID is 56, so its site
        // reads cut at 55.
        let file = String(decoding: "CmuxNextControlTests/BackgroundWorkTests+TaskTrace.swift".utf8.prefix(55), as: UTF8.self)
        #expect(posts.allSatisfy { records.site($0).file == file })
        #expect(Set(posts.map { records.site($0).line }) == [filesLine, cpuLine, systemLine])

        // BlockingLane.rawValue in bits 8-15, WorkPriority.rawValue in bits 0-7
        func site(_ lane: BlockingLane, _ priority: WorkPriority) -> UInt64 {
            UInt64(lane.rawValue) << 8 | UInt64(priority.rawValue)
        }
        let expected: [UInt64: UInt64] = [filesLine: site(.files, .bestEffort), cpuLine: site(.cpu, .userVisible),
                                          systemLine: site(.system, .userBlocking)]
        for post in posts {
            let arrival = try #require(arrivals.first { $0.arg1 == post.arg1 })
            #expect(arrival.arg0 == post.arg0, "the run names its post's site")
            #expect(arrival.timestamp >= post.timestamp)
            let begin = try #require(records.previous(arrival), "the flow-in is inside its task.run slice")
            #expect(begin.name == SignpostName.taskRun.rawValue && begin.phase == .begin)
            #expect(begin.arg0 == expected[records.site(post).line])
            #expect(begin.arg1 != TaskTrace.unknownWait, "a traced post gives its run a queue wait")
        }
    }

    @Test func withTheTaskCategoryOffNothingIsWritten() async {
        let ring = TraceRing(records: 4096, role: .app)
        let work = BackgroundWork(label: "test.task-trace.off", trace: Self.traceRuntime(ring, [.action, .control]))
        for lane in BlockingLane.allCases {
            work.post(.userVisible, mayBlock: lane, shutdown: .blockShutdown) {}
        }
        await work.shutdown()
        #expect(ring.records().isEmpty)
    }

    @Test func aRunWhosePostWasNotTracedHasNoFlowAndAnUnknownWait() throws {
        let ring = TraceRing(records: 4096, role: .app)
        let runtime = Self.traceRuntime(ring, [])
        let trace = TaskTrace(runtime: runtime)
        let ticket = trace.post(fileID: #fileID, line: #line, lane: .main)
        runtime.setCategoryMask(1 << UInt64(SignpostCategory.task.traceBit))
        let value = ticket.run(priority: TaskTrace.code(.automation)) { 7 }
        #expect(value == 7)

        let records = try TaskRecords(ring)
        #expect(records.named(.taskPost, .flowOut).isEmpty)
        #expect(records.named(.taskRun, .flowIn).isEmpty)
        let begins = records.named(.taskRun, .begin)
        #expect(begins.map(\.arg1) == [TaskTrace.unknownWait])
        #expect(begins.map(\.arg0) == [3 << 8 | UInt64(MainWorkClass.automation.rawValue)])
        #expect(records.named(.taskRun, .end).count == 1)
    }
}
