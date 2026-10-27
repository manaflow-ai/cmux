import CmuxNextLaunch
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Darwin
import Dispatch
import Testing

/// The launch's design-mode cleanup and CLI pointer write are fenced files-lane posts
/// (p08-startup-083, Q12): held behind the launch's best-effort fence until startup completes, then
/// run on the files lane at the QoS their `Task.detached` had (`.background`, `.utility`), never higher.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct LaunchFileJobsTests {
    struct Ran: Sendable {
        var job: String
        var queue: String
        var qos: UInt32

        static func here(_ job: String) -> Ran {
            Ran(job: job, queue: String(cString: __dispatch_queue_get_label(nil)), qos: qos_class_self().rawValue)
        }
    }

    @Test func theJobsWaitForStartupCompleteThenRunOnTheFilesLaneAtTheirOldQoS() async throws {
        let (queued, queue) = AsyncStream.makeStream(of: WorkPriority.self)
        let background = BackgroundWork(label: "test.launchfiles", onQueued: { lane, priority in
            if lane == .files { queue.yield(priority) }
        })
        let s = StartupTestScheduler(background: background)
        let order = LaunchOrder(fence: LaunchOrder.BestEffortFence(raisingOn: background, clock: ManualClock()),
                                mainWork: s.mainWork, startup: s.startup) { _ in }
        let (runs, run) = AsyncStream.makeStream(of: Ran.self)
        LaunchFileJobs(removeDesignModeTempFiles: { run.yield(.here("cleanup")) },
                       publishCLIPointer: { run.yield(.here("pointer")) }).post(on: background)
        // A post reports a held item before it returns: both are queued although their slots are free.
        queue.finish()
        var levels: [WorkPriority] = []
        for await priority in queued { levels.append(priority) }
        #expect(levels == [.idle, .bestEffort], "a launch file job ran before startup completed")
        s.complete()
        var seen: [String: Ran] = [:]
        for await ran in runs {
            seen[ran.job] = ran
            if seen.count == 2 { break }
        }
        let cleanup = try #require(seen["cleanup"]), pointer = try #require(seen["pointer"])
        #expect(cleanup.queue.hasPrefix("test.launchfiles.files.idle."), "ran on \(cleanup.queue)")
        #expect(cleanup.qos == QOS_CLASS_BACKGROUND.rawValue)
        #expect(pointer.queue.hasPrefix("test.launchfiles.files.bestEffort."), "ran on \(pointer.queue)")
        #expect(pointer.qos == QOS_CLASS_UTILITY.rawValue)
        _ = order
    }

    @Test func aLaunchThatMustNotClaimTheCLIPostsOnlyTheCleanup() async {
        let (queued, queue) = AsyncStream.makeStream(of: WorkPriority.self)
        let background = BackgroundWork(label: "test.launchfiles.isolated", onQueued: { lane, priority in
            if lane == .files { queue.yield(priority) }
        })
        let (runs, run) = AsyncStream.makeStream(of: String.self)
        background.beginBestEffortFence()
        LaunchFileJobs(removeDesignModeTempFiles: { run.yield("cleanup") }, publishCLIPointer: nil).post(on: background)
        queue.finish()
        var levels: [WorkPriority] = []
        for await priority in queued { levels.append(priority) }
        #expect(levels == [.idle])
        background.endBestEffortFence()
        var iterator = runs.makeAsyncIterator()
        #expect(await iterator.next() == "cleanup")
    }
}
