import CmuxNextTestSupport
import CmuxUpdater
import Foundation
@testable import CmuxNextUpdater
import Testing

/// The automatic updater's pause (Leo, 2026-11-24: "so pasuse the auto updateer for now"): with
/// ``UpdaterService/pausesAutomaticUpdates`` on, the settings that would check, download or relaunch by
/// themselves change nothing, and the person's own check still runs.
@MainActor @Suite(.serialized) struct AutomaticUpdatePauseTests {
    static func updater(paused: Bool, defaults: UserDefaults? = nil) -> UpdaterService {
        let identity = UpdateBuildIdentity(bundleIdentifier: "com.cmuxterm.app.debug.automatic-update-pause", shortVersion: "1.0.0",
                                           build: "100", minimumSystemVersion: nil,
                                           infoFeedURL: "https://files-next.cmux.com/nightly-next/appcast-arm64.xml", hasPublicKey: false)
        let defaults = defaults ?? UserDefaults(testSuiteName: "AutomaticUpdatePauseTests.\(UUID().uuidString)")!
        let updater = UpdaterService(identity: identity, policy: ManagedUpdatePolicy { false }, defaults: defaults,
                                     enableSparkle: false, recordsUpdates: false, pausesAutomaticUpdates: paused)
        updater.announcementsFetch = false
        updater.start()
        return updater
    }

    @Test func theAppsUpdaterIsNotPaused() {
        #expect(!AutomaticUpdatePause.app, "the Automatic Updates switch cannot turn on while paused")
    }

    @Test func pausedSettingsCheckDownloadAndInstallNothingByThemselves() {
        let updater = Self.updater(paused: true)
        updater.configure(checkAutomatically: true, checkInterval: 3600, downloadAutomatically: true, metered: .download,
                          ring: "nightly", installWhenIdleMinutes: 30)
        #expect(!updater.automaticUpdates, "the Automatic Updates box claims downloads while paused")
        #expect(!updater.downloadsFoundUpdates, "a found update downloads by itself while paused")
        #expect(updater.installWhenIdle == nil, "Update When Idle relaunches while paused")
        #expect(!updater.tipCheck.automatic, "the fast check reads the feed by itself while paused")
        #expect(!updater.releasePushMayRun, "the release push checks by itself while paused")
    }

    @Test func unpausedSettingsStillApply() {
        let updater = Self.updater(paused: false)
        updater.configure(checkAutomatically: true, checkInterval: 3600, downloadAutomatically: true, metered: .download,
                          ring: "nightly", installWhenIdleMinutes: 30)
        #expect(updater.automaticUpdates)
        #expect(updater.installWhenIdle == .seconds(30 * 60))
        #expect(updater.tipCheck.automatic)
    }

    /// The person's Check for Updates is not paused: a found update is offered (the titlebar's Update
    /// Available), and its Update click downloads it.
    @Test func thePersonsCheckStillOffersTheUpdate() {
        let updater = Self.updater(paused: true)
        updater.configure(checkAutomatically: true, checkInterval: 3600, downloadAutomatically: true)
        updater.send(.checkRequested)
        #expect(updater.card == .checking, "the person's check showed nothing while paused")
        updater.debugIndicatorPhase = .available(version: "2.0")
        #expect(updater.availableButton == UpdateAvailableButton(version: "2.0") || updater.card != nil,
                "the person's check found an update and offered nothing")
    }
}
