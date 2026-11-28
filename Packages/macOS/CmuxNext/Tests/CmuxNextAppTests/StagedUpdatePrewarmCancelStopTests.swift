import CmuxNextTestSupport
@testable import CmuxNextUpdater
import Foundation
import Testing

/// cmux#63767, as Leo's updater log tells it: build 4608107539201 staged at 01:43:02Z and its pre-warm started; at
/// 01:43:03 the ring had the newer 4608514080101, so the staged installer was cancelled to stage that one. Sparkle's
/// installer removed the staging folder while the pre-warm's `cmux` still loaded from it: it died in dyld at 01:43:04
/// ("Library not loaded: @rpath/Sparkle.framework", the crash report's capture time), a run later found no file.
/// Every cancel of a staged update stops its pre-warm first, as every install does.
@MainActor @Suite(.serialized) struct StagedUpdatePrewarmCancelStopTests {
    /// What the stand-in for Sparkle's cancel saw.
    @MainActor final class Cancel {
        var count = 0
        var prewarmStopped: Bool?
    }

    @Test func aNewerBuildStopsTheStagedBuildsPrewarmBeforeItsInstallerIsCancelled() async throws {
        let h = UpdateStagedYieldsToNewerTests.make(ring: "nightly")
        let seen = StagedUpdatePrewarmInstallStopTests.Seen()
        let (gate, open) = AsyncStream<Void>.makeStream()
        defer { open.finish() }
        h.updater.prewarmRunner = { _ in
            // A pre-warm whose processes still run: it ends only when stopped (or when the test ends).
            await withTaskCancellationHandler {
                for await _ in gate {}
            } onCancel: {
                seen.cancelled.withLock { $0 = true }
                open.finish()
            }
            return "pre-warmed"
        }
        // The staged build 300's own pre-warm, the one the staging started.
        h.updater.prewarmRun = nil
        #expect(h.updater.prewarmStagedUpdate() == nil, "\(h.updater.log.recent)")
        let cancel = Cancel()
        h.updater.cancelStaged = {
            cancel.count += 1
            cancel.prewarmStopped = seen.cancelled.withLock { $0 }
            return true
        }
        // Dev has the newer build 500: the staged 300 gives way (Leo's case was a newer Nightly; the path is one).
        h.updater.follow(ring: "dev")
        try await UpdateStagedYieldsToNewerTests().settle(h, fetches: 1)
        #expect(cancel.count == 1, "the staged build kept its installer: \(h.updater.log.recent)")
        #expect(cancel.prewarmStopped == true, "Sparkle's cancel removed the staging folder under a pre-warm still running")
        #expect(h.updater.log.recent.contains("launch pre-warm of 300: stopped: the staged update was cancelled"),
                "\(h.updater.log.recent)")
    }

    /// A quit with the update staged: Sparkle installs it as the app exits, and the pre-warm's processes, which outlive
    /// the app, would still load from the folder the installer moves. The decided quit stops them first.
    @Test func aQuitThatInstallsTheStagedUpdateStopsItsPrewarm() async throws {
        let updater = StagedUpdatePrewarmInstallStopTests.updater()
        let seen = StagedUpdatePrewarmInstallStopTests.Seen()
        let (gate, open) = AsyncStream<Void>.makeStream()
        defer { open.finish() }
        updater.prewarmRunner = { _ in
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
        _ = updater.prepareForQuit()
        #expect(seen.cancelled.withLock { $0 }, "the app quit with the staged build's pre-warm still running")
        #expect(updater.log.recent.contains("launch pre-warm of 200: stopped for the quit"), "\(updater.log.recent)")
    }

    /// A pre-warm that already ended is left as it was: the cancel logs no stop.
    @Test func aCancelAfterThePrewarmEndedLogsNoStop() async throws {
        let updater = StagedUpdatePrewarmInstallStopTests.updater()
        updater.prewarmRunner = { _ in "pre-warmed" }
        updater.followStagedUpdate(.ready(version: "2.0.0"))
        #expect(await StagedUpdatePrewarmTests().eventually(.seconds(5)) { updater.prewarmRun?.line != nil }, "the pre-warm never ended")
        updater.cancelStaged = { true }
        #expect(updater.cancelStagedUpdate())
        #expect(!updater.log.recent.contains { $0.contains("stopped: the staged update was cancelled") }, "\(updater.log.recent)")
    }
}
