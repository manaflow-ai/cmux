@testable import CmuxNextApp
import CmuxNextLaunch
import CmuxNextWakeups
import Testing

/// The launch's temporary-file cleanup is an afterStartup post: it never competes
/// with the first window and its first content, and runs once after startup completes.
@MainActor @Suite(.timeLimit(.minutes(1))) struct LaunchCleanupTests {
    @Test func theCleanupRunsOnceAfterStartupCompletes() {
        let f = LaunchOrderFixture()
        let runs = CleanupRuns()
        LaunchCleanup(cleanUpDownloadTempFiles: { runs.count += 1 }).schedule(on: f.order.startup)
        let restore = f.order.startup.hold("WindowManager.restore")
        f.complete()
        for _ in 0..<3 { f.fire() }
        #expect(runs.count == 0, "the cleanup ran while a visible pane still loaded")
        restore.release(.visiblePaneLoadedIdle)
        f.hand.drain()
        for _ in 0..<3 { f.fire() }
        #expect(runs.count == 1)
        #expect(f.order.startup.log.records.map(\.name.description) == ["LaunchCleanup.downloadTempFiles"])
    }

    @Test func aQuitBeforeCompletionNeverRunsTheCleanup() {
        let f = LaunchOrderFixture()
        let runs = CleanupRuns()
        LaunchCleanup(cleanUpDownloadTempFiles: { runs.count += 1 }).schedule(on: f.order.startup)
        f.order.startup.beginQuit()
        f.complete()
        for _ in 0..<3 { f.fire() }
        #expect(runs.count == 0)
    }
}

@MainActor
private final class CleanupRuns {
    var count = 0
}
