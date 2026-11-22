import CmuxNextDesign
import Testing
@testable import CmuxNextApp

/// The launch hook for deferred cleanup (`LaunchCleanup`): the download
/// temp-file cleanup runs once the launch settles, exactly once, and not
/// before. Each test uses its own `LaunchSettle` and `LaunchReveal`.
@MainActor
@Suite struct LaunchCleanupTests {
    final class Counter {
        var runs = 0
    }

    @Test func downloadTempFileCleanupRunsOnceWhenTheLaunchSettles() {
        let counter = Counter()
        let settle = LaunchSettle(reveal: LaunchReveal())
        LaunchCleanup(cleanUpDownloadTempFiles: { counter.runs += 1 }).schedule(on: settle)
        #expect(counter.runs == 0, "the cleanup waits for the launch to settle")
        settle.settle()
        #expect(counter.runs == 1)
        settle.settle()
        #expect(counter.runs == 1, "a second settle does not run the cleanup again")
    }

    @Test func cleanupScheduledAfterTheSettleRunsAtOnceAndOnce() {
        let counter = Counter()
        let settle = LaunchSettle(reveal: LaunchReveal())
        settle.settle()
        LaunchCleanup(cleanUpDownloadTempFiles: { counter.runs += 1 }).schedule(on: settle)
        #expect(counter.runs == 1)
        settle.settle()
        #expect(counter.runs == 1)
    }
}
