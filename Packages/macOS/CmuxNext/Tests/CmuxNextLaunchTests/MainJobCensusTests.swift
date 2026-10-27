#if DEBUG || CMUX_BENCH_HOOKS
@testable import CmuxNextLaunch
@testable import CmuxNextWakeups
import Foundation
import Testing

/// The main-job census (p08-startup-080, queue Q11): the run-loop turns and stretches it cuts, the enqueuer it names,
/// the StartupScheduler task that covers a turn, and the payload `startup-queue.py mainjobs` reads.
struct MainJobCensusTests {
    private static let ms: UInt64 = 1_000_000

    private static func tally(_ slot: Int, nanos: UInt64) -> MainJobRing.Tally {
        var tally = MainJobRing.Tally()
        tally.jobs = 1
        tally.nanos = nanos
        tally.longestSlot = slot
        tally.longestNanos = nanos
        return tally
    }

    /// Three turns from 1 ms: a scheduler task's sources turn, a turn of main jobs, and one outside the run loop.
    private static func threeTurns() -> MainTurnSegments {
        var turns = MainTurnSegments(startingAt: 1 * ms)
        let none = MainJobRing.Tally()
        turns.record(.entry, at: 2 * ms, jobs: none)
        turns.record(.beforeSources, at: 2 * ms, jobs: none)
        turns.record(.beforeWaiting, at: 12 * ms, jobs: none)
        turns.record(.rendered, at: 13 * ms, jobs: none)
        turns.record(.afterWaiting, at: 20 * ms, jobs: none)
        turns.record(.beforeSources, at: 20 * ms + ms / 2, jobs: none)
        turns.record(.beforeWaiting, at: 24 * ms, jobs: tally(0, nanos: 2 * ms))
        turns.record(.rendered, at: 24 * ms + ms / 2, jobs: none)
        turns.record(.afterWaiting, at: 30 * ms, jobs: none)
        turns.record(.exit, at: 30 * ms + ms / 20, jobs: none)
        turns.record(.exited, at: 30 * ms + ms / 10, jobs: none)
        turns.record(.entry, at: 35 * ms, jobs: none)
        turns.record(.beforeWaiting, at: 35 * ms + ms / 10, jobs: none)
        turns.record(.rendered, at: 35 * ms + ms / 5, jobs: none)
        return turns
    }

    @Test func turnsSplitIntoPhasesWithoutTheMainJobs() throws {
        let turns = Self.threeTurns()
        #expect(turns.turns.count == 3)
        let first = turns.turns[0], second = turns.turns[1]
        #expect((first.startNanos, first.durationNanos) == (1 * Self.ms, 12 * Self.ms))
        #expect((first.nanos(.outside), first.nanos(.sources), first.nanos(.render)) == (Self.ms, 10 * Self.ms, Self.ms))
        #expect(second.nanos(.sources) == Self.ms * 3 / 2, "3.5 ms of sources less the 2 ms main job")
        #expect((second.jobs.jobs, second.jobs.nanos, second.jobs.longestSlot) == (1, 2 * Self.ms, 0))
        #expect(second.nanos(.wake) == Self.ms / 2)
        // A stretch under the 0.1 ms floor (the third turn's 0.05 ms wake) is not a segment.
        #expect(turns.segments.map(\.phase) == [.sources, .wake, .sources])
        #expect(turns.segments.map(\.nanos) == [10 * Self.ms, Self.ms / 2, Self.ms * 3 / 2])
    }

    @Test func shortTurnsAreCountedAndTheListIsBounded() {
        var turns = MainTurnSegments(startingAt: 0, turnCapacity: 1)
        let none = MainJobRing.Tally()
        turns.record(.rendered, at: 2 * Self.ms, jobs: none)
        turns.record(.afterWaiting, at: 10 * Self.ms, jobs: none)
        turns.record(.rendered, at: 10 * Self.ms + Self.ms / 2, jobs: none)
        turns.record(.afterWaiting, at: 20 * Self.ms, jobs: none)
        turns.record(.rendered, at: 25 * Self.ms, jobs: none)
        #expect(turns.turns.map(\.durationNanos) == [2 * Self.ms], "the sleep between turns is no turn's time")
        #expect((turns.shortTurns, turns.droppedTurns) == (1, 1))
    }

    @Test func theReportNamesEnqueuersTagsTaskTurnsAndAllowlistsOutsideTurns() throws {
        let job0 = MainJobRing.Job(slot: 0, kind: .mainActor, enqueuedNanos: 11 * Self.ms, runNanos: 2 * Self.ms,
                                   priority: 0x19, frames: [1, 2, 3])
        let job1 = MainJobRing.Job(slot: 1, kind: .mainDelivery, enqueuedNanos: 21 * Self.ms, runNanos: Self.ms / 2,
                                   priority: 0x11, frames: [1, 2, 3])
        let snapshot = MainJobCensus.Snapshot(hook: .installed, processStartNanos: Self.ms, frozen: true, jobs: [job0, job1],
                                              pendingJobs: 0, droppedJobs: 0, segments: Self.threeTurns(),
                                              tasks: [.init(name: "Theme.apply", startNanos: 2 * Self.ms, durationNanos: 8 * Self.ms)])
        var stacks = 0
        let report = MainJobCensusReport(snapshot) { _ in
            stacks += 1
            return [.init(image: "cmux", symbol: "MainJobRing.recordEnqueue(_:priority:)", imageOffset: 1),
                    .init(image: "libswift_Concurrency.dylib", symbol: "swift_task_enqueueMainExecutor", imageOffset: 2),
                    .init(image: "cmux", symbol: "HomeFeed.start()", imageOffset: 3)]
        }
        #expect(stacks == 1, "one symbolication per distinct stack")
        let jobs = report.mainJobs
        #expect(jobs.prefix(2).map(\.caller) == ["HomeFeed.start()", "HomeFeed.start()"])
        #expect(jobs.prefix(2).map(\.kind) == ["main_actor", "main_delivery"])
        #expect(jobs.prefix(2).map(\.priority) == ["userInitiated", "utility"])
        #expect((jobs[0].enqueuedMs, jobs[0].runMs) == (10, 2))
        // The task covered 8 of the first sources stretch's 10 ms: 2 ms are left; the third turn's wake was under the floor.
        let stretches = jobs.dropFirst(2).map { "\($0.kind) \($0.caller) \($0.enqueuedMs) \($0.runMs)" }
        #expect(stretches == ["run_loop_sources run_loop.sources 1.0 2.0", "run_loop_wake run_loop.wake 19.0 0.5",
                              "run_loop_sources run_loop.sources 19.5 1.5"])
        let turns = report.mainTurns
        #expect(turns.map(\.task) == ["Theme.apply", nil, nil])
        #expect(turns.map(\.site) == ["run_loop.sources", "HomeFeed.start()", "outside_run_loop"])
        #expect(turns.map(\.allowlisted) == [false, false, true])
        #expect((turns[1].jobs, turns[1].jobMs) == (1, 2))
        #expect(report.census == MainJobCensusReport.Summary(hook: "installed", frozen: true, jobs: 2, pendingJobs: 0,
                                                             droppedJobs: 0, shortTurns: 0, droppedTurns: 0, droppedSegments: 0))
    }

    @Test func thePayloadHasTheKeysTheQueueReads() throws {
        let snapshot = MainJobCensus.Snapshot(hook: .missing, processStartNanos: 0, frozen: false, jobs: [], pendingJobs: 0,
                                              droppedJobs: 0, segments: Self.threeTurns(), tasks: [])
        let object = try #require(try MainJobCensusReport(snapshot) { _ in [] }.foundationObject() as? [String: Any])
        #expect(Set(object.keys) == ["main_job_census", "main_jobs", "main_turns"])
        let census = try #require(object["main_job_census"] as? [String: Any])
        #expect(census["hook"] as? String == "missing" && census["armed"] as? Bool == true)
        let turn = try #require((object["main_turns"] as? [[String: Any]])?.first)
        #expect(Set(turn.keys) == ["start_ms", "duration_ms", "task", "allowlisted", "site", "jobs", "job_ms"])
        #expect(turn["task"] is NSNull)
        let stretch = try #require((object["main_jobs"] as? [[String: Any]])?.first)
        #expect(Set(stretch.keys) == ["caller", "kind", "priority", "enqueued_ms", "run_ms"] && stretch["priority"] is NSNull)
    }

    @Test func theCallerSkipsTheRuntimeAndTheCensus() {
        let runtime = MainJobCensusReport.Frame(image: "libdispatch.dylib", symbol: "_dispatch_call_block_and_release", imageOffset: 8)
        let delivery = MainJobCensusReport.Frame(image: "cmux", symbol: "MainDelivery.run(_:)", imageOffset: 9)
        let unnamed = MainJobCensusReport.Frame(image: "cmux", symbol: nil, imageOffset: 0x10)
        #expect(MainJobCensusReport.caller([delivery, runtime, unnamed]) == "cmux+0x10")
        #expect(MainJobCensusReport.caller([delivery, runtime]) == "_dispatch_call_block_and_release", "every frame skipped: the outermost one")
        #expect(MainJobCensusReport.caller([]) == "?")
    }

    @MainActor @Test func aFrozenCensusRecordsNothingAndItsRingTakesNoJob() {
        let ring = MainJobRing(capacity: 4) { 0 }
        let census = MainJobCensus(ring: ring, hook: .installed, processStartNanos: 0)
        census.freeze()
        census.record(.rendered, at: 5 * Self.ms)
        #expect(census.snapshot(mainTasks: []).segments.turns.isEmpty)
        #expect(census.snapshot(mainTasks: []).frozen)
        #expect(ring.recordEnqueue(.mainActor, priority: 21) == nil)
    }

    @MainActor @Test func noCensusUnlessTheLaunchArmsIt() {
        #expect(MainJobCensus.armed(environment: [:], processStartNanos: 0) == nil)
        #expect(MainJobCensus.armed(environment: [MainJobCensus.environmentKey: "0"], processStartNanos: 0) == nil)
    }
}
#endif
