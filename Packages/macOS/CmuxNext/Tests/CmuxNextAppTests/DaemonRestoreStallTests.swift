import AppKit
import CmuxNextCompat
@testable import CmuxNextDaemon
@testable import CmuxNextDaemonRecovery
@testable import CmuxNextDaemonService
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// After `server.restore_timeout` (the owner's startup jobs stalled for cmux-tui's bound) the window offers Retry Now and
/// Restart cmux-tui. Only real start progress may take it back to "restoring": a report from another owner (a restart, a
/// successor), or one whose startup jobs changed. A background job's heartbeat is no start progress (cmux-tui's
/// `startup_progress_mark` counts only jobs that block `startup`), and a new attempt forgets the stall. Reports reach the
/// service through the launcher's `OwnerRestoreProgress`, as they do from `server ensure` lines and `long-jobs.json`.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct DaemonRestoreStallTests {
    private static func job(_ id: String, updated: Int64, blocks: [LongJob.Block] = [.startup]) -> LongJob {
        LongJob(id: id, kind: LongJob.outputCleanupKind, title: "Cleaning up stored terminal output", done: 10, total: 100,
                startedMs: 1, updatedMs: updated, blocks: blocks)
    }

    /// A started local service whose first attempt never ends (until shutdown), with its restore reports, past its
    /// startup deadline.
    private static func started() async throws -> (DaemonService, OwnerRestoreProgress, ManualClock) {
        let daemon = DaemonService()
        let clock = ManualClock(), never = ManualClock()
        daemon.startupClock = clock
        let progress = OwnerRestoreProgress()
        daemon.followRestoreProgress(progress)
        daemon.start(first: {
            try? await never.sleep(for: .seconds(3600))
            return .failure(.notConnected)
        }, makeConnection: { DaemonConnection(endpoint: DaemonEndpoint(socketPath: "/nonexistent/cnrst.sock")) })
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(11))
        for await passed in ObservationStream({ daemon.startupDeadlinePassed }) where passed { break }
        return (daemon, progress, clock)
    }

    /// Notes `report` and returns once the service took it (its `restoreReportsSeen` moved).
    private static func report(_ report: OwnerRestoreProgress.Report, to progress: OwnerRestoreProgress,
                               _ daemon: DaemonService) async {
        let before = daemon.restoreReportsSeen
        progress.note(report)
        for await seen in ObservationStream({ daemon.restoreReportsSeen }) where seen > before { break }
    }

    @Test func afterAStallOnlyStartProgressOrANewOwnerRestoresAgain() async throws {
        let (daemon, progress, _) = try await Self.started()
        await Self.report(.init(pid: 10, jobs: [Self.job("a", updated: 100)]), to: progress, daemon)
        #expect(daemon.startup.isRestoring)

        daemon.noteStartupFailure(.sessionRestoreTimedOut("no progress for 120 s"))
        #expect(daemon.startup.isUnavailable, "a stall past the deadline offers Retry Now and Restart")

        // The same owner: its startup job unchanged, only a background job beats.
        await Self.report(.init(pid: 10, jobs: [Self.job("a", updated: 100), Self.job("bg", updated: 900, blocks: [.none])]),
                          to: progress, daemon)
        #expect(daemon.startup.isUnavailable, "a background heartbeat read as start progress: \(daemon.startup)")

        // A new owner (Restart cmux-tui, a successor): its jobs are progress whatever they say.
        await Self.report(.init(pid: 11, jobs: [Self.job("x", updated: 50)]), to: progress, daemon)
        #expect(daemon.startup.restoringJobs.map(\.id) == ["x"])
        await daemon.shutdownConnectionAndWait()
    }

    @Test func aStallThatNamedNoJobsTakesTheFirstStartJobAndANewAttemptForgetsIt() async throws {
        let (daemon, progress, clock) = try await Self.started()
        // An owner that named no job (an older daemon) stalled.
        daemon.noteStartupFailure(.sessionRestoreTimedOut("no progress for 120 s"))
        #expect(daemon.startup.isUnavailable)
        await Self.report(.init(pid: 10, jobs: []), to: progress, daemon)
        #expect(daemon.startup.isUnavailable, "a report with no start job is no progress")
        await Self.report(.init(pid: 10, jobs: [Self.job("a", updated: 100)]), to: progress, daemon)
        #expect(daemon.startup.restoringJobs.map(\.id) == ["a"], "the stall's owner moved on: \(daemon.startup)")

        // Stalled again on that job; Retry Now's new attempt forgets the stall.
        daemon.noteStartupFailure(.sessionRestoreTimedOut("no progress for 120 s"))
        #expect(daemon.startup.isUnavailable)
        daemon.beginAttempt()
        #expect(daemon.startup == .connecting)
        await Self.report(.init(pid: 10, jobs: [Self.job("a", updated: 100)]), to: progress, daemon)
        #expect(daemon.startup.isRestoring, "the stall outlived a new attempt")
        _ = clock
        await daemon.shutdownConnectionAndWait()
    }

    @Test func noReportMovesAStoppedService() async throws {
        let (daemon, progress, _) = try await Self.started()
        await daemon.shutdownConnectionAndWait()
        let before = daemon.startup
        progress.note(.init(pid: 10, jobs: [Self.job("a", updated: 100)]))
        // The hop runs on the main actor after this turn: give it the turn, then nothing changed.
        await Task.yield()
        await Task.yield()
        #expect(daemon.startup == before)
        #expect(daemon.restoreReportsSeen == 0)
    }

    /// "Don't quit" only for a job that quitting would interrupt; the Activity popover keeps a job's row across its
    /// progress steps (VoiceOver keeps its place) and drops the rows of jobs that ended.
    @Test func dontQuitOnlyForAQuitJobAndPopoverRowsKeepTheirViews() {
        let view = DaemonConnectingView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.apply(.restoring([Self.job("a", updated: 1)]))
        #expect(view.guidanceText == nil, "a job that does not block quit said don't quit")
        view.apply(.restoring([Self.job("a", updated: 1, blocks: [.startup, .quit])]))
        #expect(view.guidanceText == DaemonRecoveryStrings.dontQuit)

        let popover = ActivityPopoverView()
        popover.update([Self.job("a", updated: 1), Self.job("b", updated: 1)])
        let first = popover.rowViews
        #expect(first.count == 2)
        var stepped = Self.job("a", updated: 2)
        stepped.done = 50
        popover.update([stepped, Self.job("b", updated: 1)])
        #expect(popover.rowViews.map(ObjectIdentifier.init) == first.map(ObjectIdentifier.init), "a progress step rebuilt the rows")
        popover.update([stepped])
        #expect(popover.rowViews.count == 1)
        #expect(popover.rowViews.first === first.first)
    }
}
