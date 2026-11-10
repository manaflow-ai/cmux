import CmuxNextTestSupport
import Foundation
@testable import CmuxNextUpdater
import Testing

/// Leo 2026-10-27: "and the whole check for updates thing, we can do it more properly to ask
/// before the download + install step, and likewise for the reboot... to make it more like how
/// it'd be in prod". On every channel (stable, NIGHTLY, the tip app, DEV) a found update asks
/// before it downloads (the update-found step: Update / Release Notes / Hide), and the downloaded
/// update asks before the relaunch (the Update Ready card: Restart to Update / Hide). Hide, or no
/// answer, never relaunches; a quit installs it only with `updates.installOnQuit` on (the nightly
/// restart policy keeps it off by default). The automatic-download opt-in
/// (`updates.downloadAutomatically`) only skips the first ask.
@MainActor @Suite(.serialized) struct UpdateAsksBeforeInstallTests {
    nonisolated static let stable = UpdateBuildIdentity(bundleIdentifier: "com.cmuxterm.app", shortVersion: "0.70.0", build: "100",
                                                        minimumSystemVersion: nil, infoFeedURL: TipAppTrackTests.stableFeed, hasPublicKey: true)
    nonisolated static let nightly = TipUpdateCheckTests.nightly
    nonisolated static let tip = TipUpdateCheckTests.tip
    nonisolated static let dev = UpdateBuildIdentity(bundleIdentifier: "com.cmuxterm.app.debug.asks-before-install", shortVersion: "0.1.0", build: "100",
                                                     minimumSystemVersion: nil, infoFeedURL: "https://files-next.cmux.com/nightly-next/appcast-arm64.xml",
                                                     hasPublicKey: false)
    nonisolated static let channels = [stable, nightly, tip, dev]

    /// What the updater asked Sparkle for.
    @MainActor final class Effects {
        var downloads = 0
        var installs = 0
        var cancels = 0
    }

    /// An updater for `identity` with the given `updates.downloadAutomatically` (off by default:
    /// these tests are about the asks, which the nightly ring's default skips) or the channel's
    /// default (`optIn` nil); downloads, installs and cancels are counted.
    static func make(_ identity: UpdateBuildIdentity, optIn: Bool? = false) -> (UpdaterService, Effects) {
        let updater = UpdaterService(identity: identity, policy: ManagedUpdatePolicy { false },
                                     defaults: UserDefaults(testSuiteName: "UpdateAsksBeforeInstallTests.\(UUID().uuidString)")!,
                                     enableSparkle: false, recordsUpdates: false)
        updater.announcementsFetch = false
        updater.notesLoader = { _ in nil }
        let effects = Effects()
        updater.acceptAvailable = { effects.downloads += 1 }
        updater.installStaged = { effects.installs += 1 }
        updater.cancelStaged = { effects.cancels += 1; return true }
        updater.preflightOverride = { nil }
        updater.configure(checkAutomatically: true, checkInterval: 3600,
                          downloadAutomatically: optIn ?? identity.track.downloadsAutomaticallyByDefault)
        updater.applyDownloadPolicy() // the driver's configure runs it; this updater has no driver
        // Not started: no fast check timer and no release push socket (their own tests cover them).
        return (updater, effects)
    }

    /// Leo 2026-11-10: "the nightly automatically downloads and installs/unpacks and you simply
    /// click and it restarts with the new version". cmux NEXT's nightly ring (NEXT and the tip app)
    /// downloads found updates by default; stable, RC, classic NIGHTLY and DEV still ask. No channel
    /// relaunches by itself: Restart to Update stays the one click.
    @Test func onlyTheNightlyRingDownloadsByDefault() {
        for track in UpdateTrack.allCases {
            #expect(track.downloadsAutomaticallyByDefault == (track == .nightlyNext),
                    "\(track) downloadsAutomaticallyByDefault is \(track.downloadsAutomaticallyByDefault)")
        }
        for identity in Self.channels {
            let (updater, _) = Self.make(identity, optIn: nil)
            let nightlyRing = identity.track == .nightlyNext
            #expect(updater.automaticUpdates == nightlyRing && updater.downloadsFoundUpdates == nightlyRing,
                    "\(identity.track) (tip \(identity.isTipBuild)) downloads found updates by default: \(updater.downloadsFoundUpdates)")
        }
    }

    /// On the nightly ring's default a found update stages with no click, and nothing relaunches
    /// until Restart to Update, the one click.
    @Test func aNightlyStagesByItselfAndRestartToUpdateIsTheOneClick() async throws {
        let (updater, effects) = Self.make(Self.nightly, optIn: nil)
        #expect(updater.identity.track == .nightlyNext)
        updater.debugIndicatorPhase = .checking
        updater.debugIndicatorPhase = .downloading(.starting)
        updater.debugIndicatorPhase = .ready(version: "2.0.0")
        try await Task.sleep(for: .milliseconds(50))
        #expect(updater.availableButton == nil, "the nightly asked before it downloaded")
        #expect(effects.installs == 0, "the nightly relaunched without a click")
        let ready = try #require(updater.readyCard, "the staged nightly shows no Restart to Update")
        #expect(ready.buttonTitle == UpdaterStrings.restartToUpdate && !ready.isInstalling)
        updater.installClicked()
        #expect(await eventually { effects.installs == 1 }, "Restart to Update did not install")
    }

    /// Found, nobody asked (a scheduled check, the fast check, a release push): the titlebar's
    /// Update Available asks, and nothing downloads until its click.
    @Test(arguments: UpdateAsksBeforeInstallTests.channels)
    func aFoundUpdateAsksBeforeItDownloads(identity: UpdateBuildIdentity) {
        let (updater, effects) = Self.make(identity)
        updater.debugIndicatorPhase = .checking
        updater.debugIndicatorPhase = .available(version: "2.0.0")
        #expect(updater.availableButton == UpdateAvailableButton(version: "2.0.0"), "\(identity.track): the found update did not ask")
        #expect(effects.downloads == 0, "\(identity.track): the found update downloaded without an answer")
        #expect(updater.readyCard == nil)
    }

    /// Check for Updates: the found update's card shows its version, Update and Release Notes, and
    /// Hide; Update downloads it with its progress, and the staged update asks before the
    /// relaunch. Only Restart to Update installs and relaunches.
    @Test(arguments: UpdateAsksBeforeInstallTests.channels)
    func checkForUpdatesAsksBeforeTheDownloadAndBeforeTheRelaunch(identity: UpdateBuildIdentity) async throws {
        let (updater, effects) = Self.make(identity)
        updater.send(.checkRequested)
        updater.debugIndicatorPhase = .checking
        #expect(updater.card == .checking)
        updater.debugIndicatorPhase = .available(version: "2.0.0")
        #expect(updater.card == .available(version: "2.0.0"))
        let found = try #require(updater.cardPresentation)
        #expect(found.actions == [.update, .releaseNotes] && found.dismissible, "\(identity.track): the found step offers \(found.actions)")
        #expect(effects.downloads == 0)

        // Update: the download starts and shows; nothing installs.
        updater.performCardAction(.update)
        #expect(effects.downloads == 1, "\(identity.track): Update did not download")
        #expect(!updater.flow.installRequested, "\(identity.track): Update on the found step also asked to relaunch")
        updater.debugIndicatorPhase = .downloading(UpdateTransfer(stage: .downloading, fraction: 0.5))
        #expect(updater.card == .downloading(UpdateTransfer(stage: .downloading, fraction: 0.5)), "the download shows no progress")

        // Staged: the Update Ready card asks; nothing relaunches by itself.
        updater.debugIndicatorPhase = .ready(version: "2.0.0")
        try await Task.sleep(for: .milliseconds(50))
        #expect(effects.installs == 0, "\(identity.track): the staged update relaunched without asking")
        let ready = try #require(updater.readyCard, "\(identity.track): the staged update did not ask before the relaunch")
        #expect(ready.buttonTitle == UpdaterStrings.restartToUpdate && !ready.isInstalling)
        #expect(updater.card == nil, "the notice card stayed beside the Update Ready card")

        // Restart to Update: installs and relaunches.
        updater.installClicked()
        #expect(await eventually { effects.installs == 1 }, "\(identity.track): Restart to Update did not install")
    }

    /// Later (the Update Ready card's Hide): no relaunch. A quit installs it only with
    /// `updates.installOnQuit` on; by default (the nightly restart policy) the quit cancels the
    /// pending installer and the next check offers the update again.
    @Test(arguments: UpdateAsksBeforeInstallTests.channels)
    func laterNeverRelaunches(identity: UpdateBuildIdentity) async throws {
        let (updater, effects) = Self.make(identity)
        updater.debugIndicatorPhase = .available(version: "2.0.0")
        updater.downloadClicked()
        updater.debugIndicatorPhase = .downloading(.starting)
        updater.debugIndicatorPhase = .ready(version: "2.0.0")
        #expect(updater.readyCard != nil)
        updater.closeUpdateCard(.hideVersion)
        #expect(updater.readyCard == nil, "Later left the Update Ready card")
        try await Task.sleep(for: .milliseconds(50))
        #expect(effects.installs == 0, "Later relaunched")
        #expect(updater.prepareForQuit() == .cancelPendingInstall, "a quit installed the update nobody asked to install")
        #expect(effects.cancels == 1)
        updater.preferences.installOnQuit = true
        #expect(updater.prepareForQuit() == .proceed, "with install on quit on, the quit does not install it")
    }

    /// The opt-in (`updates.downloadAutomatically` on) skips the first ask only: found updates
    /// download by themselves, a click on one whose download was deferred (a metered link) only
    /// downloads it, and the staged update still waits for Restart to Update.
    @Test(arguments: UpdateAsksBeforeInstallTests.channels)
    func theOptInDownloadsButStillAsksBeforeTheRelaunch(identity: UpdateBuildIdentity) async throws {
        let (updater, effects) = Self.make(identity, optIn: true)
        #expect(updater.downloadsFoundUpdates && updater.automaticUpdates, "\(identity.track): the opt-in does not download by itself")
        updater.debugIndicatorPhase = .available(version: "2.0.0")
        updater.downloadClicked()
        #expect(!updater.flow.installRequested, "\(identity.track): a click on a deferred download skipped the relaunch's ask")
        updater.debugIndicatorPhase = .downloading(.starting)
        updater.debugIndicatorPhase = .ready(version: "2.0.0")
        try await Task.sleep(for: .milliseconds(50))
        #expect(effects.installs == 0, "\(identity.track): the opted-in update relaunched without a click")
        #expect(updater.readyCard != nil, "\(identity.track): the opted-in update did not ask before the relaunch")
        updater.installClicked()
        #expect(await eventually { effects.installs == 1 }, "\(identity.track): Restart to Update did not install")
    }

    /// A repeated or late Update (pressed again while the download runs, or after it staged) never
    /// turns into Restart to Update: the staged update still asks.
    @Test func aRepeatedUpdateNeverAsksToRelaunch() async throws {
        let (updater, effects) = Self.make(Self.nightly)
        updater.debugIndicatorPhase = .available(version: "2.0.0")
        updater.performCardAction(.update)
        updater.debugIndicatorPhase = .downloading(.starting)
        updater.performCardAction(.update)
        UpdateSheetModel(service: updater).perform(.update)
        #expect(!updater.flow.installRequested, "a second Update during the download asked to relaunch")
        updater.debugIndicatorPhase = .ready(version: "2.0.0")
        updater.performCardAction(.update)
        try await Task.sleep(for: .milliseconds(50))
        #expect(effects.downloads == 1 && effects.installs == 0, "a repeated Update relaunched")
        #expect(updater.readyCard != nil)
    }

    /// The update sheet (no sidebar showing the cards) asks the same way: its found step offers
    /// Update, which only downloads.
    @Test func theSheetsFoundStepOnlyDownloads() {
        let (updater, effects) = Self.make(Self.nightly)
        #expect(UpdateSheetButton.update.title == UpdaterStrings.update && !UpdateSheetButton.update.dismisses)
        updater.debugIndicatorPhase = .available(version: "2.0.0")
        UpdateSheetModel(service: updater).perform(.update)
        #expect(effects.downloads == 1, "the sheet's Update did not download")
        #expect(!updater.flow.installRequested, "the sheet's Update also asked to relaunch")
    }

    func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }
}
