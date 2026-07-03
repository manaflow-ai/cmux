import Foundation
import Sparkle
import Testing
@testable import CmuxUpdater

/// Coverage for the 1-click auto-update flow: the automatic-downloads migration, the
/// update-ready toast's visibility rules, the deferred restart-when-idle loop, and the
/// transient-error classification the silent retry relies on.
@MainActor
@Suite struct OneClickUpdateTests {
    // MARK: - Settings migration (v3: automatic downloads on)

    private func makeScratchDefaults() throws -> UserDefaults {
        let suiteName = "cmux-updater-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test func migrationEnablesAutomaticDownloadsOverV2ExplicitFalse() throws {
        let defaults = try makeScratchDefaults()
        // A v2-era install: the old migration wrote an explicit false.
        defaults.set(false, forKey: UpdateSettings.automaticallyUpdateKey)
        defaults.set(true, forKey: UpdateSettings.migrationKey)

        UpdateSettings().apply(to: defaults)

        #expect(defaults.bool(forKey: UpdateSettings.automaticallyUpdateKey))
        #expect(defaults.bool(forKey: UpdateSettings.automaticDownloadsMigrationKey))
    }

    @Test func migrationRunsOnceSoUserOptOutSticks() throws {
        let defaults = try makeScratchDefaults()
        UpdateSettings().apply(to: defaults)
        #expect(defaults.bool(forKey: UpdateSettings.automaticallyUpdateKey))

        // The user turns automatic downloads back off; a later launch must not re-enable it.
        defaults.set(false, forKey: UpdateSettings.automaticallyUpdateKey)
        UpdateSettings().apply(to: defaults)

        #expect(!defaults.bool(forKey: UpdateSettings.automaticallyUpdateKey))
    }

    @Test func freshInstallDefaultsToAutomaticDownloads() throws {
        let defaults = try makeScratchDefaults()
        UpdateSettings().apply(to: defaults)
        #expect(defaults.bool(forKey: UpdateSettings.automaticallyUpdateKey))
    }

    // MARK: - Update-ready toast visibility

    private func stagedInstalling(version: String? = "1.2.3",
                                  isAutoUpdate: Bool = true,
                                  onRestart: @escaping () -> Void = {}) -> UpdateState.Installing {
        .init(isAutoUpdate: isAutoUpdate,
              stagedVersion: version,
              retryTerminatingApplication: onRestart,
              dismiss: {})
    }

    @Test func toastShowsForStagedAutoUpdateOnly() {
        let model = UpdateStateModel()
        #expect(model.updateReadyToastInstalling == nil)

        model.setState(.installing(stagedInstalling(isAutoUpdate: false)))
        #expect(model.updateReadyToastInstalling == nil)

        model.setState(.installing(stagedInstalling()))
        #expect(model.updateReadyToastInstalling?.stagedVersion == "1.2.3")
    }

    @Test func dismissHidesToastForSameVersionButNotForNewerStagedVersion() {
        let model = UpdateStateModel()
        model.setState(.installing(stagedInstalling(version: "1.2.3")))
        model.dismissUpdateReadyToast()
        #expect(model.updateReadyToastInstalling == nil)

        // Same version re-staged: stays dismissed.
        model.setState(.installing(stagedInstalling(version: "1.2.3")))
        #expect(model.updateReadyToastInstalling == nil)

        // A newer release staged: the toast returns.
        model.setState(.installing(stagedInstalling(version: "1.2.4")))
        #expect(model.updateReadyToastInstalling?.stagedVersion == "1.2.4")
    }

    @Test func armingRestartWhenIdleHidesToastAndLeavingInstallingDisarms() {
        let model = UpdateStateModel()
        model.setState(.installing(stagedInstalling()))
        model.setRestartWhenIdleArmed(true)
        #expect(model.updateReadyToastInstalling == nil)
        #expect(model.text == "Restarting When Idle…")

        model.setState(.idle)
        #expect(!model.isRestartWhenIdleArmed)
    }

    @Test func muteHidesToastUntilDeadlineAcrossVersions() throws {
        let model = UpdateStateModel(defaults: try makeScratchDefaults())
        var currentTime = Date(timeIntervalSince1970: 1_000_000)
        model.now = { currentTime }

        model.setState(.installing(stagedInstalling(version: "1.2.3")))
        model.muteUpdateReadyToast(for: 60 * 60)
        #expect(model.updateReadyToastInstalling == nil)

        // A newer staged version is still muted — mute is time-based, not per-version.
        model.setState(.installing(stagedInstalling(version: "1.2.4")))
        #expect(model.updateReadyToastInstalling == nil)

        // Past the deadline the toast returns.
        currentTime = currentTime.addingTimeInterval(60 * 60 + 1)
        #expect(model.updateReadyToastInstalling?.stagedVersion == "1.2.4")
    }

    @Test func mutePersistsAcrossModelInstances() throws {
        let defaults = try makeScratchDefaults()
        let first = UpdateStateModel(defaults: defaults)
        let base = Date(timeIntervalSince1970: 2_000_000)
        first.now = { base }
        first.muteUpdateReadyToast(for: 24 * 60 * 60)

        // A relaunch constructs a fresh model over the same defaults: still muted.
        let second = UpdateStateModel(defaults: defaults)
        second.now = { base.addingTimeInterval(60) }
        second.setState(.installing(stagedInstalling()))
        #expect(second.updateReadyToastInstalling == nil)

        second.clearUpdateReadyToastMute()
        #expect(second.updateReadyToastInstalling != nil)
        #expect(defaults.object(forKey: UpdateStateModel.toastMuteDefaultsKey) == nil)
    }

    @Test func stagedInstallingPillTextOffersRestart() {
        let model = UpdateStateModel()
        model.setState(.installing(stagedInstalling()))
        #expect(model.text == "Restart to Complete Update")
    }

    @Test func stagedVersionDerivesReleaseNotesLink() {
        let installing = stagedInstalling(version: "0.65.0")
        #expect(installing.releaseNotes?.url.absoluteString == "https://github.com/manaflow-ai/cmux/releases/tag/v0.65.0")
        #expect(stagedInstalling(version: nil).releaseNotes == nil)
    }

    // MARK: - Restart when idle (controller loop)

    /// A clock whose sleeps return immediately after yielding, so the poll loop advances
    /// without real waiting.
    private struct YieldClock: UpdateClock {
        func sleep(for duration: Duration) async throws {
            await Task.yield()
        }
    }

    private final class IdleStubDelegate: UpdateActionDelegate {
        var isSafeToRestart = false
        func updaterRequestsRetryCheckForUpdates() {}
        func updaterWillRelaunchApplication() {}
        func updaterIsSafeToRestartNow() -> Bool { isSafeToRestart }
    }

    private func makeController(clock: any UpdateClock) throws -> UpdateController {
        UpdateController(
            log: NoopUpdateLog(),
            clock: clock,
            hostBundle: .main,
            defaults: try makeScratchDefaults(),
            isDevLikeBundle: false
        )
    }

    @Test func restartWhenIdleFiresInstallOnceHostReportsIdle() async throws {
        let controller = try makeController(clock: YieldClock())
        let delegate = IdleStubDelegate()
        controller.actionDelegate = delegate

        var restarted = false
        controller.model.setState(.installing(stagedInstalling(onRestart: { restarted = true })))
        controller.requestRestartWhenIdle()
        #expect(controller.model.isRestartWhenIdleArmed)

        // Busy at first: the loop must keep waiting.
        for _ in 0..<20 { await Task.yield() }
        #expect(!restarted)

        delegate.isSafeToRestart = true
        for _ in 0..<200 {
            await Task.yield()
            if restarted { break }
        }
        #expect(restarted)
    }

    @Test func restartWhenIdleStopsWhenStagedInstallGoesAway() async throws {
        let controller = try makeController(clock: YieldClock())
        let delegate = IdleStubDelegate()
        controller.actionDelegate = delegate

        var restarted = false
        controller.model.setState(.installing(stagedInstalling(onRestart: { restarted = true })))
        controller.requestRestartWhenIdle()

        // The staged install is dismissed before the host ever reports idle.
        controller.model.setState(.idle)
        #expect(!controller.model.isRestartWhenIdleArmed)

        delegate.isSafeToRestart = true
        for _ in 0..<50 { await Task.yield() }
        #expect(!restarted)
    }

    @Test func restartWhenIdleIgnoredWithoutStagedInstall() throws {
        let controller = try makeController(clock: YieldClock())
        controller.requestRestartWhenIdle()
        #expect(!controller.model.isRestartWhenIdleArmed)
    }

    // MARK: - Transient network error classification

    @Test func classifiesTransientNetworkErrors() {
        #expect(UpdateStateModel.isTransientNetworkError(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        ))
        #expect(UpdateStateModel.isTransientNetworkError(
            NSError(domain: SUSparkleErrorDomain, code: 2001)  // SUDownloadError (CDN 504, #5632)
        ))
        // A download error wrapping an NSURLError is still transient.
        #expect(UpdateStateModel.isTransientNetworkError(
            NSError(domain: SUSparkleErrorDomain, code: 2001, userInfo: [
                NSUnderlyingErrorKey: NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost),
            ])
        ))
    }

    @Test func doesNotClassifyIntegrityOrInstallerFailuresAsTransient() {
        #expect(!UpdateStateModel.isTransientNetworkError(
            NSError(domain: SUSparkleErrorDomain, code: 3001)  // SUSignatureError
        ))
        #expect(!UpdateStateModel.isTransientNetworkError(
            NSError(domain: SUSparkleErrorDomain, code: 4005)  // SUInstallationError
        ))
        #expect(!UpdateStateModel.isTransientNetworkError(
            NSError(domain: "cmux.update", code: 1)
        ))
    }
}
