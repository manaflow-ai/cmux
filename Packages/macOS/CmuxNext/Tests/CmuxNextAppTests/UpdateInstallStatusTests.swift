@testable import CmuxNextUpdater
import CmuxNextWakeupsTestSupport
import CmuxUpdater
import Foundation
import Testing

/// "Installing Update — cmux relaunches in a moment" sat for about 80 s with an
/// indeterminate bar (Lawrence 2026-10-23, nightly 3973494930601 to 3991367032401):
/// Sparkle's installer checked the new ~700 MB bundle for a minute before it
/// relaunched, and the card never said so. The installing card now says what it
/// waits on and for how long, offers Relaunch when the relaunch gate holds it, and
/// an install that never relaunches gives up: the windows come back and the card
/// says the update did not relaunch.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct UpdateInstallStatusTests {
    static func presentation(_ status: UpdateInstallStatus?) -> UpdateCardPresentation {
        UpdateCard.installing.presentation(version: "1.0.0", build: "100", install: status)
    }

    @Test func aQuickInstallKeepsTheShortText() {
        let shown = Self.presentation(UpdateInstallStatus(elapsed: .seconds(3), blockers: nil))
        #expect(shown.title == UpdaterStrings.installingUpdate)
        #expect(shown.detail == UpdaterStrings.relaunchingDetail)
        #expect(shown.showsProgress && !shown.dismissible)
    }

    @Test func aSlowInstallSaysWhatItDoesAndHowLong() throws {
        let shown = Self.presentation(UpdateInstallStatus(elapsed: .seconds(42), blockers: nil))
        let detail = try #require(shown.detail)
        #expect(detail != UpdaterStrings.relaunchingDetail, "a 42 s install still says it relaunches in a moment")
        #expect(detail.contains("42"), "the card does not say how long it has waited: \(detail)")
        #expect(shown.showsProgress)
    }

    @Test func aHeldRelaunchNamesWhatItWaitsForAndOffersRelaunch() throws {
        let held = UpdateRelaunchBlockers(busyAgentCount: 3, runningCommandCount: 0)
        let status = UpdateInstallStatus(elapsed: .seconds(5), blockers: held)
        #expect(status.stage == .waiting(agents: 3, commands: 0))
        let shown = Self.presentation(status)
        let detail = try #require(shown.detail)
        #expect(shown.title != UpdaterStrings.installingUpdate, "a held relaunch reads as installing")
        #expect(detail.contains("3"), "the card does not count what it waits for: \(detail)")
        #expect(shown.actions.contains(.relaunchNow), "nothing lets the person relaunch now: \(shown.actions)")
    }

    @Test func anInstallThatNeverRelaunchesSaysSo() {
        let status = UpdateInstallStatus(elapsed: UpdateInstallStatus.giveUpAfter + .seconds(1), blockers: nil)
        #expect(status.stage == .stalled)
        let shown = Self.presentation(status)
        #expect(shown.title != UpdaterStrings.installingUpdate)
        #expect(!shown.showsProgress, "a stuck install still spins")
        #expect(shown.dismissible)
        #expect(shown.actions.contains(.details), "no way to read why: \(shown.actions)")
    }

    /// The updater gives up on its own: the windows hidden at the click come back.
    @Test func theUpdaterGivesUpOnAnInstallThatNeverRelaunches() async throws {
        let clock = CmuxNextWakeupsTestSupport.ManualClock()
        let wall = WallClock()
        let identity = UpdateBuildIdentity(bundleIdentifier: "com.cmuxterm.app.debug.update-install-status", shortVersion: "1.0.0",
                                           build: "100", minimumSystemVersion: nil,
                                           infoFeedURL: "https://files-next.cmux.com/nightly-next/appcast-arm64.xml", hasPublicKey: false)
        let defaults = try #require(UserDefaults(suiteName: "UpdateInstallStatusTests.\(UUID().uuidString)"))
        let updater = UpdaterService(identity: identity, policy: ManagedUpdatePolicy { false }, defaults: defaults,
                                     enableSparkle: false, recordsUpdates: false, now: { wall.now }, clock: clock)
        updater.announcementsFetch = false
        var abandoned = 0
        updater.installAbandoned = { abandoned += 1 }
        updater.send(.checkRequested)
        for phase: UpdateIndicatorPhase in [.checking, .downloading(.starting), .downloading(.preparing(nil)), .installing] {
            updater.debugIndicatorPhase = phase
            updater.syncFlowPhase()
        }
        #expect(updater.card == .installing)
        #expect(updater.cardPresentation?.detail == UpdaterStrings.relaunchingDetail)

        wall.now += 30
        try await clock.waitForSleeper()
        let ticks = updater.installTick
        clock.advance(by: .seconds(30))
        // The tick must run before the wall clock moves again, or it would read the later time.
        for _ in 0..<500 where updater.installTick == ticks { try await Task.sleep(for: .milliseconds(5)) }
        #expect(updater.installTick > ticks, "the installing card's tick never ran")
        #expect(updater.cardPresentation?.detail?.contains("30") == true, "after 30 s: \(String(describing: updater.cardPresentation?.detail))")
        #expect(abandoned == 0)

        wall.now += 200
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(200))
        for _ in 0..<500 where abandoned == 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(abandoned == 1, "the hidden windows never came back")
        #expect(updater.cardPresentation?.dismissible == true)
        #expect(updater.cardPresentation?.actions.contains(.details) == true)
    }

    /// A wall clock the test moves (``UpdaterService`` reads dates through `now`).
    final class WallClock {
        var now = Date(timeIntervalSince1970: 1_792_743_000)
    }
}
