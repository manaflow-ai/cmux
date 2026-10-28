#if DEBUG || CMUX_BENCH_HOOKS
@testable import CmuxNextCompat
@testable import CmuxNextLaunch
import Foundation
import Testing

/// The main-job census (queue Q11): the run-loop turns and stretches it cuts, the enqueuer it names,
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
        #expect(turns.segments.map(\.elapsedNanos) == [10 * Self.ms, Self.ms / 2, Self.ms * 7 / 2], "the wall time keeps the job's")
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
        let job0 = MainJobRing.Job(slot: 0, kind: .mainActor, enqueuedNanos: 11 * Self.ms, runStartNanos: 21 * Self.ms,
                                   runNanos: 2 * Self.ms, priority: 0x19, frames: [1, 2, 3])
        let job1 = MainJobRing.Job(slot: 1, kind: .mainDelivery, enqueuedNanos: 21 * Self.ms, runStartNanos: 12 * Self.ms,
                                   runNanos: Self.ms / 2, priority: 0x11, frames: [1, 2, 3])
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

    private typealias Frame = MainJobCensusReport.Frame
    private static let ring = Frame(image: "cmux", symbol: "CmuxNextCompat.MainJobRing.enqueue(_:original:)", imageOffset: 1)
    private static let entry = Frame(image: "libswift_Concurrency.dylib", symbol: "swift_task_enqueueMainExecutor", imageOffset: 2)
    private static let create = Frame(image: "libswift_Concurrency.dylib", symbol: "swift_task_create", imageOffset: 3)

    @Test func theCallerSkipsTheRuntimeAndTheCensus() {
        let runtime = Frame(image: "libdispatch.dylib", symbol: "_dispatch_call_block_and_release", imageOffset: 8)
        let delivery = Frame(image: "cmux", symbol: "CmuxNextWakeups.MainDelivery.run(_:)", imageOffset: 9)
        let unnamed = Frame(image: "cmux", symbol: nil, imageOffset: 0x10)
        #expect(MainJobCensusReport.caller([delivery, runtime, unnamed], kind: .mainDelivery) == "cmux+0x10")
        #expect(MainJobCensusReport.caller([delivery, runtime], kind: .mainDelivery) == "unknown")
        #expect(MainJobCensusReport.caller([], kind: .mainDelivery) == "unknown")
    }

    /// A classed delivery hop posts through the scheduler to a run-loop block: its caller is the app frame past both.
    @Test func aClassedDeliveryHopNamesTheAppCaller() {
        let block = Frame(image: "cmux", symbol: "static CmuxNextCompat.MainRunLoopBlock.censused(_:)", imageOffset: 0x11)
        let post = Frame(image: "cmux", symbol: "CmuxNextWakeups.MainWorkScheduler.postFromAnyThread(_:owner:site:_:)", imageOffset: 0x12)
        let delivery = Frame(image: "cmux", symbol: "CmuxNextWakeups.MainDelivery.run(file:line:_:)", imageOffset: 0x13)
        let app = Frame(image: "cmux", symbol: "BrowserTab.frameChanged()", imageOffset: 0x14)
        #expect(MainJobCensusReport.caller([block, post, delivery, app], kind: .runLoopBlock) == "BrowserTab.frameChanged()")
    }

    /// A stack with nothing of the app past the runtime (an `await` resumed from a pool thread whose async frames were
    /// cut) has no enqueuer: never the thread start or a runtime frame.
    @Test func aStackOfRuntimeFramesOnlyHasAnUnknownCaller() {
        let worker = Frame(image: "libdispatch.dylib", symbol: "_dispatch_worker_thread2", imageOffset: 4)
        let start = Frame(image: "libsystem_pthread.dylib", symbol: "start_wqthread", imageOffset: 5)
        let overlay = Frame(image: "libswiftDispatch.dylib", symbol: "Dispatch.DispatchQueue.async(execute:)", imageOffset: 6)
        #expect(MainJobCensusReport.caller([Self.ring, Self.entry, Self.create, overlay, worker, start], kind: .mainActor) == "unknown")
        // Before the hook's caller the frames are the ring's: an app frame there is not the enqueuer.
        let app = Frame(image: "cmux", symbol: "HomeFeed.start()", imageOffset: 7)
        #expect(MainJobCensusReport.caller([app, Self.ring, worker, start], kind: .mainActor) == "unknown", "no libswift_Concurrency frame")
    }

    /// `Task.init` and `MainActor.run` are emitted into the caller's image and not inlined in a Debug build: they are
    /// skipped, mangled or demangled, so each `Task { }` is named by the code that wrote it.
    @Test func taskAndMainActorMembersAreNotTheCaller() {
        let taskInit = Frame(image: "cmux", symbol: "(extension in Swift):Swift.Task< where B == Swift.Never>.init(name: Swift.String?, "
                                 + "priority: Swift.TaskPriority?, operation: sending @isolated(any) () async -> A) -> Swift.Task<A, Swift.Never>",
                             imageOffset: 0x20)
        let mangled = Frame(image: "cmux", symbol: "$sScTss5NeverORs_rlE4name8priority9operationScTyxABGSSSg_ScPSgxyYaYAcntcfC", imageOffset: 0x21)
        let run = Frame(image: "cmux", symbol: "static Swift.MainActor.run<A>(resultType: A.Type, body: @MainActor () throws -> A) async throws -> A",
                        imageOffset: 0x22)
        let site = Frame(image: "cmux", symbol: "HomeFeed.start() -> Swift.Task<(), Swift.Never>", imageOffset: 0x23)
        #expect(MainJobCensusReport.caller([Self.ring, Self.entry, Self.create, taskInit, mangled, run, site], kind: .mainActor)
            == "HomeFeed.start() -> Swift.Task<(), Swift.Never>", "a function that returns a Task is a site")
    }

    /// A `MainRunLoopBlock` post is named by the code that posted it, past the seam's own frames.
    @Test func aRunLoopBlockPostIsNamedByItsPostSite() {
        let record = Frame(image: "cmux", symbol: "CmuxNextCompat.MainJobRing.recordEnqueue(_:priority:label:) -> Swift.Int?", imageOffset: 1)
        let censused = Frame(image: "cmux", symbol: "static CmuxNextCompat.MainRunLoopBlock.censused(_:) -> @MainActor () -> ()", imageOffset: 2)
        let perform = Frame(image: "cmux", symbol: "CmuxNextCompat.MainRunLoopBlock.perform(mode: __C.CFRunLoopModeRef) -> ()", imageOffset: 3)
        let site = Frame(image: "cmux", symbol: "Sidebar.reload()", imageOffset: 4)
        #expect(MainJobCensusReport.caller([record, censused, perform, site], kind: .runLoopBlock) == "Sidebar.reload()")
    }

    /// A timer fire, and the main-actor job it enqueued, are named by the timer's owner; a block is `run_loop_block`.
    @Test func timerAndRunLoopBlockJobsKeepTheirKindAndATimerItsOwner() {
        let fire = MainJobRing.Job(slot: 0, kind: .timer, enqueuedNanos: 2 * Self.ms, runStartNanos: 2 * Self.ms, runNanos: Self.ms,
                                   priority: 0x15, label: "Sidebar.refresh", frames: [9])
        let task = MainJobRing.Job(slot: 1, kind: .mainActor, enqueuedNanos: 2 * Self.ms, runStartNanos: 4 * Self.ms, runNanos: Self.ms,
                                   priority: 0x15, label: "Sidebar.refresh", frames: [9])
        let block = MainJobRing.Job(slot: 2, kind: .runLoopBlock, enqueuedNanos: 5 * Self.ms, runStartNanos: 6 * Self.ms,
                                    runNanos: Self.ms, priority: 0x21, frames: [7])
        let snapshot = MainJobCensus.Snapshot(hook: .installed, processStartNanos: 0, frozen: true, jobs: [fire, task, block],
                                              pendingJobs: 0, droppedJobs: 0, segments: MainTurnSegments(startingAt: 0), tasks: [])
        let report = MainJobCensusReport(snapshot) { _ in [Frame(image: "cmux", symbol: "Sidebar.reload()", imageOffset: 4)] }
        #expect(report.mainJobs.map(\.kind) == ["timer", "main_actor", "run_loop_block"])
        #expect(report.mainJobs.map(\.caller) == ["timer Sidebar.refresh", "timer Sidebar.refresh", "Sidebar.reload()"])
        #expect(report.mainJobs.map(\.priority) == ["default", "default", "userInteractive"])
    }

    /// One wake stretch from 10 to 20 ms holding `jobs` (their time in the tally), and the report over it with `tasks`.
    private static func wakeStretch(jobs: [MainJobRing.Job], tasks: [MainJobCensus.TaskSpan]) -> MainJobCensusReport {
        var turns = MainTurnSegments(startingAt: 0)
        var tally = MainJobRing.Tally()
        for job in jobs {
            tally.jobs += 1
            tally.nanos += job.runNanos
        }
        turns.record(.rendered, at: 0, jobs: MainJobRing.Tally())
        turns.record(.afterWaiting, at: 10 * ms, jobs: MainJobRing.Tally())
        turns.record(.beforeWaiting, at: 20 * ms, jobs: tally)
        turns.record(.rendered, at: 21 * ms, jobs: MainJobRing.Tally())
        let snapshot = MainJobCensus.Snapshot(hook: .installed, processStartNanos: 0, frozen: true, jobs: jobs, pendingJobs: 0,
                                              droppedJobs: 0, segments: turns, tasks: tasks)
        return MainJobCensusReport(snapshot) { _ in [Frame(image: "cmux", symbol: "HomeFeed.start()", imageOffset: 1)] }
    }

    /// A run-loop block that ran `runTenths` tenths of a millisecond from `startTenths`.
    private static func job(_ startTenths: UInt64, _ runTenths: UInt64) -> MainJobRing.Job {
        MainJobRing.Job(slot: 0, kind: .runLoopBlock, enqueuedNanos: 1 * ms, runStartNanos: startTenths * ms / 10,
                        runNanos: runTenths * ms / 10, priority: 0x15, frames: [1])
    }

    /// A scheduler task that ran `runTenths` tenths of a millisecond from `startTenths`.
    private static func task(_ startTenths: UInt64, _ runTenths: UInt64) -> MainJobCensus.TaskSpan {
        .init(name: "Theme.apply", startNanos: startTenths * ms / 10, durationNanos: runTenths * ms / 10)
    }

    private static func records(_ report: MainJobCensusReport) -> [String] {
        report.mainJobs.map { "\($0.kind) \($0.runMs)" }
    }

    /// A stretch's own time is its wall time less every instant a job or a scheduler task covered, each counted once,
    /// wherever in the stretch they ran.
    @Test func aStretchLosesTheUnionOfItsJobsAndTasks() {
        // One after the other, late in the stretch: 10 ms less a 4 ms job and a 3 ms task.
        let apart = Self.wakeStretch(jobs: [Self.job(110, 40)], tasks: [Self.task(150, 30)])
        #expect(Self.records(apart) == ["run_loop_block 4.0", "run_loop_wake 3.0"])
        // A 1.5 ms task inside a 4 ms job: the task's time is the job's, counted once; the job keeps the rest.
        let taskInJob = Self.wakeStretch(jobs: [Self.job(110, 40)], tasks: [Self.task(120, 15)])
        #expect(Self.records(taskInJob) == ["run_loop_block 2.5", "run_loop_wake 6.0"])
        // A job that spent most of its time running a task is the task's: no job record.
        let mostlyTask = Self.wakeStretch(jobs: [Self.job(110, 40)], tasks: [Self.task(120, 25)])
        #expect(Self.records(mostlyTask) == ["run_loop_wake 6.0"])
        // A 4 ms job inside a 6 ms task: the stretch keeps the 4 ms neither covered.
        let jobInTask = Self.wakeStretch(jobs: [Self.job(120, 40)], tasks: [Self.task(110, 60)])
        #expect(Self.records(jobInTask) == ["run_loop_wake 4.0"])
    }

    @Test func mergedIntervalsJoinOverlapsAndCoveredCountsEachInstantOnce() {
        let joined = MainJobCensusReport.merged([(start: 5, end: 9), (start: 1, end: 3), (start: 2, end: 4), (start: 6, end: 7),
                                                 (start: 8, end: 8)])
        #expect(joined.map { [$0.start, $0.end] } == [[1, 4], [5, 9]])
        #expect(MainJobCensusReport.covered(joined, 0, 10) == 7)
        #expect(MainJobCensusReport.covered(joined, 3, 6) == 2)
        #expect(MainJobCensusReport.covered(joined, 9, 12) == 0)
        #expect(MainJobCensusReport.covered([], 0, 10) == 0)
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
