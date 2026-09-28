import Foundation
import Testing
@testable import CmuxUpdater

/// The "Install Updates Automatically" setting: on by default for nightly only, and Sparkle's
/// background downloads follow it, except on DEV/staging builds and managed Macs.
@MainActor
@Suite struct AutomaticInstallSettingTests {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suiteName = "com.cmuxterm.updatertests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }

    private func makeController(
        defaults: UserDefaults,
        updater: FakeUpdater,
        isDevLikeBundle: Bool = false,
        isDisabledByPolicy: Bool = false
    ) -> UpdateController {
        UpdateController(
            log: NoopUpdateLog(),
            clock: TestDeadlineClock(),
            defaults: defaults,
            isDevLikeBundle: isDevLikeBundle,
            isDisabledByPolicy: { isDisabledByPolicy },
            updaterFactory: { _, _ in updater }
        )
    }

    @Test func defaultIsOnForNightlyOnly() throws {
        #expect(UpdateSettings.installsAutomaticallyByDefault(on: .nightly))
        #expect(!UpdateSettings.installsAutomaticallyByDefault(on: .stable))
        #expect(!UpdateSettings.installsAutomaticallyByDefault(on: .rc))

        try withDefaults { defaults in
            UpdateSettings().apply(to: defaults, channel: .nightly)
            #expect(defaults.bool(forKey: UpdateSettings.installAutomaticallyKey))
        }
        try withDefaults { defaults in
            UpdateSettings().apply(to: defaults, channel: .stable)
            #expect(!defaults.bool(forKey: UpdateSettings.installAutomaticallyKey))
        }
    }

    @Test func userChoiceOverridesTheChannelDefault() throws {
        try withDefaults { defaults in
            defaults.set(false, forKey: UpdateSettings.installAutomaticallyKey)
            UpdateSettings().apply(to: defaults, channel: .nightly)
            #expect(!defaults.bool(forKey: UpdateSettings.installAutomaticallyKey))
        }
    }

    @Test func sparkleBackgroundDownloadsFollowTheSetting() throws {
        try withDefaults { defaults in
            defaults.set(true, forKey: UpdateSettings.installAutomaticallyKey)
            let updater = FakeUpdater()
            let controller = makeController(defaults: defaults, updater: updater)
            #expect(controller.installsAutomatically)
            #expect(updater.automaticallyDownloadsUpdates)
            #expect(controller.driver.installsAutomatically())

            defaults.set(false, forKey: UpdateSettings.installAutomaticallyKey)
            controller.installAutomaticallyDidChange()
            #expect(!updater.automaticallyDownloadsUpdates)
            #expect(!controller.driver.installsAutomatically())
        }
    }

    /// With automatic installs on, the launch check downloads the update, so a nightly user
    /// gets it at the next quiet moment instead of after Sparkle's next scheduled check.
    @Test func launchCheckDownloadsWhenInstallsAreAutomatic() throws {
        try withDefaults { defaults in
            defaults.set(true, forKey: UpdateSettings.installAutomaticallyKey)
            let updater = FakeUpdater()
            updater.automaticallyChecksForUpdates = true
            let controller = makeController(defaults: defaults, updater: updater)
            #expect(controller.startUpdaterIfNeeded())
            #expect(updater.checkForUpdatesInBackgroundCallCount == 1)
            #expect(updater.checkForUpdateInformationCallCount == 0)
        }
        try withDefaults { defaults in
            defaults.set(false, forKey: UpdateSettings.installAutomaticallyKey)
            let updater = FakeUpdater()
            updater.automaticallyChecksForUpdates = true
            let controller = makeController(defaults: defaults, updater: updater)
            #expect(controller.startUpdaterIfNeeded())
            #expect(updater.checkForUpdatesInBackgroundCallCount == 0)
            #expect(updater.checkForUpdateInformationCallCount == 1)
        }
    }

    @Test func devBuildsAndManagedMacsNeverInstallOnTheirOwn() throws {
        try withDefaults { defaults in
            defaults.set(true, forKey: UpdateSettings.installAutomaticallyKey)
            let devUpdater = FakeUpdater()
            let dev = makeController(defaults: defaults, updater: devUpdater, isDevLikeBundle: true)
            #expect(!dev.installsAutomatically)
            #expect(!devUpdater.automaticallyDownloadsUpdates)

            let managedUpdater = FakeUpdater()
            let managed = makeController(defaults: defaults, updater: managedUpdater, isDisabledByPolicy: true)
            #expect(!managed.installsAutomatically)
            #expect(!managedUpdater.automaticallyDownloadsUpdates)
        }
    }
}
