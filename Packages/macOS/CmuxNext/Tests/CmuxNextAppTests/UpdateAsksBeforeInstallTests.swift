import Foundation
@testable import CmuxNextUpdater
import Testing

/// Leo 2026-10-27: "and the whole check for updates thing, we can do it more properly to ask
/// before the download + install step, and likewise for the reboot... to make it more like how
/// it'd be in prod". On every channel (stable, NIGHTLY, the tip app, DEV) both steps exist: a
/// found update asks before it downloads (the update-found step: Update / Release Notes / Hide),
/// and the downloaded update asks before the relaunch (the Update Ready card: Restart to Update /
/// Hide). Hide, or no answer, never relaunches; a quit installs it only with
/// `updates.installOnQuit` on (the nightly restart policy keeps it off by default).
///
/// The automatic-download opt-in (`updates.downloadAutomatically`) only ever skips the first ask.
/// Its channel default is off where prod is (stable, RC, tagged DEV) and on for NIGHTLY and the
/// tip app (Leo 2026-10-26: "Opt in to automatically download. I want to be optted in"), so these
/// tests pass `optIn:` explicitly wherever they exercise one side of it.
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

    /// An updater for `identity` with the channel's default (`optIn` nil) or the given
    /// `updates.downloadAutomatically`; downloads, installs and cancels are counted.
    static func make(_ identity: UpdateBuildIdentity, optIn: Bool? = nil) -> (UpdaterService, Effects) {
        let updater = UpdaterService(identity: identity, policy: ManagedUpdatePolicy { false },
                                     defaults: UserDefaults(suiteName: "UpdateAsksBeforeInstallTests.\(UUID().uuidString)")!,
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

    /// The channel default: stable, RC and tagged DEV ask before the download, as prod does;
    /// NIGHTLY and the tip app are opted in (Leo 2026-10-26: "Opt in to automatically download. I
    /// want to be optted in"). Every channel still asks before the relaunch
    /// (``theChannelDefaultStillAsksBeforeTheRelaunch``).
    @Test func theChannelDefaultIsOptInWhereProdIsAndOnInNightly() {
        for track in UpdateTrack.allCases {
            #expect(track.downloadsAutomaticallyByDefault == (track == .nightly), "\(track)'s channel default")
        }
        for identity in Self.channels {
            let (updater, _) = Self.make(identity)
            let expected = identity.track.downloadsAutomaticallyByDefault
            #expect(updater.automaticUpdates == expected && updater.downloadsFoundUpdates == expected,
                    "\(identity.track) (tip \(identity.isTipBuild)) does not follow its channel default")
        }
    }

    /// The NIGHTLY and tip default downloads the found update by itself, and the staged update
    /// still waits on the Update Ready card: Leo 2026-10-26 ("I don't want to have to click check
    /// for updates to get the update. I just want the update. Opt in to automatically download. I
    /// want to be optted in") and Leo 2026-10-27 ("likewise for the reboot") both hold.
    @Test(arguments: [UpdateAsksBeforeInstallTests.nightly, UpdateAsksBeforeInstallTests.tip])
    func theChannelDefaultStillAsksBeforeTheRelaunch(identity: UpdateBuildIdentity) async throws {
        let (updater, effects) = Self.make(identity)
        #expect(updater.downloadsFoundUpdates, "\(identity.track) (tip \(identity.isTipBuild)) is not opted in by default")
        updater.debugIndicatorPhase = .available(version: "2.0.0")
        updater.debugIndicatorPhase = .downloading(.starting)
        updater.debugIndicatorPhase = .ready(version: "2.0.0")
        try await Task.sleep(for: .milliseconds(50))
        #expect(effects.installs == 0, "\(identity.track): the opted-in default relaunched without a click")
        #expect(updater.readyCard != nil, "\(identity.track): the opted-in default did not ask before the relaunch")
        updater.installClicked()
        #expect(await eventually { effects.installs == 1 }, "\(identity.track): Restart to Update did not install")
    }

    /// Found, nobody asked (a scheduled check, the fast check, a release push): the titlebar's
    /// Update Available asks, and nothing downloads until its click.
    @Test(arguments: UpdateAsksBeforeInstallTests.channels)
    func aFoundUpdateAsksBeforeItDownloads(identity: UpdateBuildIdentity) {
        let (updater, effects) = Self.make(identity, optIn: false)
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
        let (updater, effects) = Self.make(identity, optIn: false)
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
        let (updater, effects) = Self.make(identity, optIn: false)
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
        let (updater, effects) = Self.make(Self.nightly, optIn: false)
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
        let (updater, effects) = Self.make(Self.nightly, optIn: false)
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
