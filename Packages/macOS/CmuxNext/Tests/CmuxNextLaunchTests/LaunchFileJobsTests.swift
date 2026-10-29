import CmuxNextLaunch
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Darwin
import Dispatch
import Testing

/// Where and at what QoS a launch file job ran; built on the files-lane thread that runs it.
nonisolated private struct Ran: Sendable {
    var job: String
    var queue: String
    var qos: UInt32

    static func here(_ job: String) -> Ran {
        Ran(job: job, queue: String(cString: __dispatch_queue_get_label(nil)), qos: qos_class_self().rawValue)
    }
}

/// The launch's design-mode cleanup and CLI pointer write are files-lane posts (Q12):
/// the cleanup is held behind the launch's best-effort fence until the reveal, then runs at
/// `.background`; the pointer is not held (a script that opens the app and runs `cmux` at once gets this
/// app's CLI) and survives a quit during startup.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct LaunchFileJobsTests {
    @Test func theCleanupWaitsForTheRevealAndThePointerIsWrittenAtOnce() async throws {
        let (queued, queue) = AsyncStream.makeStream(of: WorkPriority.self)
        let background = BackgroundWork(label: "test.launchfiles", onQueued: { lane, priority in
            if lane == .files { queue.yield(priority) }
        })
        let s = StartupTestScheduler(phase: StartupPhase(clock: ManualClock(), ledger: WakeupLedger()), background: background)
        let order = LaunchOrder(fence: LaunchOrder.BestEffortFence(raisingOn: background),
                                mainWork: s.mainWork, startup: s.startup) { _ in }
        s.mainWork.startup.noteLaunch(.window)
        let (runs, run) = AsyncStream.makeStream(of: Ran.self)
        LaunchFileJobs(removeDesignModeTempFiles: { run.yield(.here("cleanup")) },
                       publishCLIPointer: { run.yield(.here("pointer")) }).post(on: background)
        // A post reports a held item before it returns: only the cleanup is held, its slot is free.
        queue.finish()
        var levels: [WorkPriority] = []
        for await priority in queued { levels.append(priority) }
        #expect(levels == [.idle], "the CLI pointer waited for the reveal")
        var iterator = runs.makeAsyncIterator()
        let pointer = try #require(await iterator.next())
        #expect(pointer.job == "pointer", "the cleanup ran before the reveal")
        #expect(pointer.queue.hasPrefix("test.launchfiles.files.userVisible."), "ran on \(pointer.queue)")
        s.mainWork.startup.noteFirstFrame() // the reveal lowers the fence
        let cleanup = try #require(await iterator.next())
        #expect(cleanup.job == "cleanup")
        #expect(cleanup.queue.hasPrefix("test.launchfiles.files.idle."), "ran on \(cleanup.queue)")
        #expect(cleanup.qos == QOS_CLASS_BACKGROUND.rawValue)
        _ = order
    }

    @Test func aQuitDuringStartupStillWritesThePointer() async {
        let (queued, queue) = AsyncStream.makeStream(of: WorkPriority.self)
        let background = BackgroundWork(filesWidths: .serial, label: "test.launchfiles.quit", onQueued: { lane, priority in
            if lane == .files { queue.yield(priority) }
        })
        background.beginBestEffortFence()
        // Hold the pointer's slot so the pointer is still queued when quit starts.
        let (started, start) = AsyncStream.makeStream(of: Void.self)
        let release = DispatchSemaphore(value: 0)
        background.post(.userVisible, mayBlock: .files) {
            start.yield()
            release.wait()
        }
        var startedIterator = started.makeAsyncIterator()
        _ = await startedIterator.next()
        let (runs, run) = AsyncStream.makeStream(of: String.self)
        LaunchFileJobs(removeDesignModeTempFiles: { run.yield("cleanup") },
                       publishCLIPointer: { run.yield("pointer") }).post(on: background)
        queue.finish()
        var levels: [WorkPriority] = []
        for await priority in queued { levels.append(priority) }
        #expect(levels == [.idle, .userVisible])
        background.beginShutdown()
        release.signal()
        var iterator = runs.makeAsyncIterator()
        #expect(await iterator.next() == "pointer", "quit dropped the CLI pointer")
        await background.shutdown()
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
