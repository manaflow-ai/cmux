import CmuxNextTestSupport
@testable import CmuxNextUpdater
@testable import CmuxUpdater
import Foundation
@preconcurrency import Sparkle
import Testing

/// cmux#63767: an automatic idle install (Update When Idle, nobody clicked) stops the staged build's pre-warm before the
/// installer moves the staged copy, on both of its paths. The driver hands the staged update to the app (the moment
/// hold ends at once here), then either the app quits for the install and reopens behind (Leo's NIGHTLY: "will install",
/// "relaunching for update", then "install: started"), or Sparkle relaunches it. Sparkle 2.10.0 calls
/// `updater(_:willInstallUpdate:)` and `updaterWillRelaunchApplication(_:)` from `installerWillFinishInstallationAndRelaunch:`
/// before it sends the installer `SPUResumeInstallationToStage2`, the stage that moves the files.
@MainActor @Suite(.serialized) struct StagedUpdateIdleInstallPrewarmTests {
    /// What the app's quit-and-reopen helper saw when the install started it.
    @MainActor final class Quit {
        var started = false
        var prewarmStopped: Bool?
    }

    /// The app's updater with a staged build 200 whose pre-warm still runs (until it is stopped), the disk preflight
    /// passing and the rollback copy already kept, so the automatic install goes as far as the handoff.
    static func updater(_ seen: StagedUpdatePrewarmInstallStopTests.Seen) -> (UpdaterService, AsyncStream<Void>.Continuation) {
        let updater = StagedUpdatePrewarmInstallStopTests.updater()
        let (gate, open) = AsyncStream<Void>.makeStream()
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
        updater.preflightOverride = { nil }
        updater.keptRunningBuild = .kept
        return (updater, open)
    }

    /// The driver of an app that keeps its sessions across a relaunch (cmux NEXT): it installs staged updates by itself
    /// when idle and asks the app how to relaunch.
    static func driver(host: UpdaterService) -> UpdateDriver {
        let driver = UpdateDriver(model: UpdateStateModel(), log: host.log, clock: SystemUpdateClock())
        driver.actionDelegate = host
        driver.installsInBackground = true
        driver.installsWhenIdle = true
        driver.holdsUserInstalls = false
        return driver
    }

    static let item = SUAppcastItem(dictionary: [
        "title": "cmux NEXT 2.0.0",
        "pubDate": "Wed, 25 Nov 2026 12:00:00 +0000",
        "enclosure": [
            "url": "https://example.invalid/cmux.dmg",
            "length": "1024",
            "sparkle:version": "200",
            "sparkle:shortVersionString": "2.0.0",
        ],
    ])!

    /// Leo's path: the app is in the background, so it quits for the install and reopens behind. The pre-warm is
    /// stopped before the helper that quits the app starts.
    @Test func anIdleInstallThatReopensBehindStopsThePrewarmBeforeTheAppQuits() async throws {
        let seen = StagedUpdatePrewarmInstallStopTests.Seen()
        let (updater, open) = Self.updater(seen)
        defer { open.finish() }
        let quit = Quit()
        updater.relaunchBehind = { _, _, _ in
            quit.started = true
            quit.prewarmStopped = seen.cancelled.withLock { $0 }
        }
        let driver = Self.driver(host: updater)
        driver.showReady(toInstallAndRelaunch: { _ in })
        #expect(quit.started, "the idle install did not quit the app: \(updater.log.recent)")
        #expect(quit.prewarmStopped == true, "the app started quitting for the install while the pre-warm still ran")
        #expect(updater.log.recent.contains("launch pre-warm of 200: stopped for the install"), "\(updater.log.recent)")
    }

    /// The app is in front (or has no reopen helper): the driver gives Sparkle the install reply, and Sparkle's
    /// will-install callback, which comes before the installer's second stage, stops the pre-warm.
    @Test func anIdleInstallThatSparkleRelaunchesStopsThePrewarmBeforeTheFilesMove() async throws {
        let seen = StagedUpdatePrewarmInstallStopTests.Seen()
        let (updater, open) = Self.updater(seen)
        defer { open.finish() }
        let driver = Self.driver(host: updater)
        let reply = ChoiceRecord()
        driver.showReady(toInstallAndRelaunch: { choice in MainActor.assumeIsolated { reply.choice = choice } })
        #expect(reply.choice == .install, "the idle install did not reach Sparkle: \(updater.log.recent)")
        // What Sparkle's installer driver does next, in this order, before it sends the installer to stage 2.
        let sparkle = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: driver)
        driver.updater(sparkle, willInstallUpdate: Self.item)
        #expect(seen.cancelled.withLock { $0 }, "Sparkle's will-install left the pre-warm running")
        driver.updaterWillRelaunchApplication(sparkle)
        #expect(updater.log.recent.contains("launch pre-warm of 200: stopped for the install"), "\(updater.log.recent)")
    }

    /// The reply the driver gave Sparkle.
    @MainActor final class ChoiceRecord {
        var choice: SPUUserUpdateChoice?
    }
}
