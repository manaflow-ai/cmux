#if DEBUG || CMUX_BENCH_HOOKS
@testable import CmuxNextLaunch
import CmuxNextWakeups
import Dispatch
import Foundation
import Testing

/// The off-main job census (queue Q12): a task kept once at its first enqueue, the counts of what is
/// not kept, the bounds, the creator the report names, and the payload `startup-queue.py globaljobs` reads.
nonisolated struct GlobalJobCensusTests {
    private static let ms: UInt64 = 1_000_000

    private static func census(capacity: Int = 16) -> GlobalJobCensus {
        GlobalJobCensus(capacity: capacity, processStartNanos: Self.ms, clock: { 3 * Self.ms + Self.ms / 2 })
    }

    private static func frame(_ image: String, _ symbol: String? = nil, offset: UInt = 0x1f) -> GlobalJobCensusReport.Frame {
        .init(image: image, symbol: symbol, imageOffset: offset)
    }

    /// The census's own frames, then the runtime's from the hook's caller on, then `creator`'s.
    private static func stack(_ creator: [GlobalJobCensusReport.Frame]) -> [GlobalJobCensusReport.Frame] {
        [frame("cmux DEV", "CmuxNextLaunch.GlobalJobCensus.record(taskID:priority:onMain:)"),
         frame("cmux DEV", "closure #1 in CmuxNextLaunch.GlobalJobCensus.hookBits"),
         frame("libswift_Concurrency.dylib"), frame("libswift_Concurrency.dylib", "swift_task_create")] + creator
    }

    @Test func aTaskIsKeptAtItsFirstEnqueueAndTheRestCounted() throws {
        let census = Self.census()
        let slot = census.record(taskID: 7, priority: 17, onMain: false)
        #expect(slot == 0)
        #expect(census.record(taskID: 7, priority: 17, onMain: false) == nil, "a resumption")
        #expect(census.record(taskID: 0, priority: 21, onMain: true) == nil, "a default actor's run")
        #expect(census.record(taskID: GlobalJobCensus.taskIDLimit, priority: 9, onMain: false) == nil, "past the bitmap")
        let snapshot = census.snapshot()
        let job = try #require(snapshot.jobs.first)
        #expect(snapshot.jobs.count == 1)
        #expect((job.taskID, job.priority, job.onMain, job.enqueuedNanos) == (7, 17, false, 3 * Self.ms + Self.ms / 2))
        #expect(!job.frames.isEmpty, "the recording thread's stack")
        #expect(snapshot.counts == GlobalJobCensus.Counts(pending: 0, dropped: 0, resumptions: 1, actorJobs: 1, untracked: 1))
        #expect(snapshot.hook == .notInstalled)
    }

    @Test func theRingIsBoundedAndFreezeStopsIt() {
        let census = Self.census(capacity: 2)
        let slots = ([1, 2, 3] as [UInt64]).map { census.record(taskID: $0, priority: 9, onMain: false) }
        #expect(slots == [0, 1, nil])
        census.freeze()
        #expect(census.record(taskID: 4, priority: 9, onMain: false) == nil)
        #expect(census.record(taskID: 1, priority: 9, onMain: false) == nil)
        let snapshot = census.snapshot()
        #expect(snapshot.frozen)
        #expect(snapshot.jobs.map(\.taskID) == [1, 2])
        #expect((snapshot.counts.dropped, snapshot.counts.resumptions) == (1, 0), "nothing after the freeze is counted")
    }

    @Test func threadsThatRaceOnOneTaskKeepItOnce() {
        let census = Self.census(capacity: 256)
        DispatchQueue.concurrentPerform(iterations: 1_000) { index in
            _ = census.record(taskID: UInt64(index % 100) + 1, priority: 17, onMain: false)
        }
        let snapshot = census.snapshot()
        #expect(Set(snapshot.jobs.map(\.taskID)) == Set(1 ... 100))
        #expect(snapshot.jobs.count == 100)
        #expect(snapshot.counts.resumptions == 900)
    }

    @Test func aCensusIsArmedOnlyByItsVariable() {
        #expect(GlobalJobCensus.armed(environment: [:], processStartNanos: 0) == nil)
        #expect(GlobalJobCensus.armed(environment: [GlobalJobCensus.environmentKey: "0"], processStartNanos: 0) == nil)
    }

    @Test func theCreatorIsTheFirstFramePastTheRuntime() {
        let creator = GlobalJobCensusReport.creator(Self.stack([Self.frame("libdispatch.dylib"), Self.frame("CoreFoundation"),
                                                                Self.frame("cmux DEV", "Feed.refresh()"), Self.frame("cmux DEV", "Feed.start()")]))
        #expect(creator.caller == "Feed.refresh()")
        #expect(creator.via == nil)
        // Task.detached emitted into the app image (a Debug build does not inline it) is not the creator.
        let detached = Self.frame("cmux DEV", "static Swift.Task< where B == Swift.Error>.detached(priority: Swift.TaskPriority?, operation: __owned @Sendable () async throws -> A) -> Swift.Task<A, Swift.Error>")
        let specialized = Self.frame("cmux DEV", "generic specialization <Swift.Int> of Swift.TaskGroup.addTask(priority:operation:)")
        #expect(GlobalJobCensusReport.creator(Self.stack([detached, specialized, Self.frame("cmux DEV", "Feed.start()")])).caller == "Feed.start()")
        // Without a name (a stripped image), the image and offset.
        #expect(GlobalJobCensusReport.creator(Self.stack([Self.frame("cmux DEV", offset: 0x2a)])).caller == "cmux DEV+0x2a")
        // No frame of the hook's caller: the stack was not one the hook took.
        #expect(GlobalJobCensusReport.creator([Self.frame("cmux DEV", "Feed.refresh()")]).caller == "?")
    }

    @Test func aBackgroundWorkTaskIsNamedByItsCallerAndMarked() {
        let task = Self.frame("cmux DEV", "generic specialization <Swift.Bool> of CmuxNextWakeups.BackgroundWork.task<A where A: Swift.Sendable>(_: CmuxNextWakeups.WorkPriority, shutdown: CmuxNextWakeups.ShutdownBehavior, fileID: Swift.StaticString, line: Swift.UInt, _: sending @isolated(any) () async throws -> A) -> Swift.Task<A, Swift.Error>")
        let creator = GlobalJobCensusReport.creator(Self.stack([task, Self.frame("cmux DEV", "Index.rebuild()")]))
        #expect(creator.caller == "Index.rebuild()")
        #expect(creator.via == GlobalJobCensusReport.backgroundWorkTask)
        #expect(BackgroundWork.ownTaskFrames.allSatisfy { !"CmuxNextWakeups.BackgroundWork.taskFinished(_:site:since:)".contains($0) })
    }

    @Test func theReportIsWhatGlobaljobsReads() throws {
        let census = Self.census()
        census.record(taskID: 3, priority: 0, onMain: true)
        let report = GlobalJobCensusReport(census.snapshot()) { _ in Self.stack([Self.frame("cmux DEV", "Scan.all()")]) }
        let object = try #require(report.foundationObject() as? [String: Any])
        let jobs = try #require(object["global_jobs"] as? [[String: Any]])
        let job = try #require(jobs.first)
        #expect(job["caller"] as? String == "Scan.all()")
        #expect(job["priority"] as? Int == 0)
        #expect(job["origin"] as? String == "main")
        #expect(job["enqueued_ms"] as? Double == 2.5)
        #expect(job["via"] is NSNull)
        #expect(job["lane"] == nil, "a census task never runs on a lane, and globaljobs skips laned jobs")
        #expect(job["run_ms"] is NSNull, "the hook sees the enqueue, not the run")
        let summary = try #require(object["global_job_census"] as? [String: Any])
        #expect(summary["armed"] as? Bool == true)
        #expect(summary["hook"] as? String == "not_installed")
        #expect(summary["tasks"] as? Int == 1)
        #expect(summary["dropped_tasks"] as? Int == 0)
    }
}
#endif
