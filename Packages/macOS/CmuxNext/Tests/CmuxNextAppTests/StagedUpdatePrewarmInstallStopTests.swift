import CmuxNextTestSupport
import CmuxNextWakeups
import Foundation
import os
@testable import CmuxNextUpdater
import Testing

/// cmux#63767: Leo's NIGHTLY installed the update 4608514080101 one second after it staged, while the staged copy's
/// pre-warm still ran. Sparkle swapped that copy into /Applications and removed the staging folder under the pre-warm's
/// processes: the staged app's own run died in dyld ("Library not loaded: @rpath/Sparkle.framework", SIGABRT), a crash
/// report for a process nobody started. Every install stops the pre-warm first, so no pre-warm process runs files the
/// installer moves.
@MainActor @Suite(.serialized) struct StagedUpdatePrewarmInstallStopTests {
    /// Records that the stand-in pre-warm was cancelled.
    final class Seen: Sendable {
        // A one-flag compare-and-set written from the cancellation handler, read by the bounded wait (lock carve-out).
        let cancelled = OSAllocatedUnfairLock(initialState: false)
    }

    @Test func theInstallStopsAPrewarmThatStillRuns() async throws {
        let updater = Self.updater()
        let seen = Seen()
        let (gate, open) = AsyncStream<Void>.makeStream()
        defer { open.finish() }
        updater.prewarmRunner = { _ in
            // A pre-warm whose processes still run: it ends only when stopped (or when the test ends).
            await withTaskCancellationHandler {
                for await _ in gate {}
            } onCancel: {
                seen.cancelled.withLock { $0 = true }
                open.finish()
            }
            return "pre-warmed"
        }
        updater.followStagedUpdate(.ready(version: "2.0.0"))
        #expect(updater.prewarmedBuild == "200")
        // Sparkle's relaunch hook, which every install reaches before the installer moves the staged copy.
        updater.updaterWillRelaunchApplication()
        #expect(await eventually { seen.cancelled.withLock { $0 } }, "the install left the pre-warm running")
        #expect(updater.log.recent.contains("launch pre-warm of 200: stopped for the install"), "\(updater.log.recent)")
    }

    @Test func aPrewarmThatEndedIsLeftAsItWas() async throws {
        let updater = Self.updater()
        updater.prewarmRunner = { _ in "pre-warmed" }
        updater.followStagedUpdate(.ready(version: "2.0.0"))
        #expect(await eventually { updater.prewarmRun?.line != nil }, "the pre-warm never ended")
        updater.updaterWillRelaunchApplication()
        #expect(!updater.log.recent.contains("launch pre-warm of 200: stopped for the install"), "\(updater.log.recent)")
    }

    /// The pre-warm suite's updater, with a frontmost app of its own: the relaunch hook reads it, and a test has no NSApp.
    static func updater() -> UpdaterService {
        let updater = StagedUpdatePrewarmTests.updater(stagedBuild: "200")
        updater.frontmost = { UpdateFrontmostApp(isThisApp: false, pid: 1, bundleID: nil) }
        return updater
    }

    /// The pre-warm suite's bounded wait (one check per pass).
    func eventually(_ condition: () -> Bool) async -> Bool { await StagedUpdatePrewarmTests().eventually(.seconds(5), condition) }
}
