import Foundation
@testable import CmuxNextUpdater
import Testing

/// Leo 2026-10-27: "and the whole check for updates thing, we can do it more properly to ask
/// before the download + install step, and likewise for the reboot... to make it more like how
/// it'd be in prod". On every channel (stable, NIGHTLY, the tip app, DEV) a found update asks
/// before it downloads (the update-found step: Update / Release Notes / Hide), and the downloaded
/// update asks before the relaunch (the Update Ready card: Restart to Update / Hide); Hide, or no
/// answer, installs it at the next quit and never relaunches. Only the automatic-install opt-in
/// (`updates.downloadAutomatically`) downloads, installs and relaunches by itself (#25904).
@MainActor @Suite(.serialized) struct UpdateAsksBeforeInstallTests {
    static let stable = UpdateBuildIdentity(bundleIdentifier: "com.cmuxterm.app", shortVersion: "0.70.0", build: "100",
                                            minimumSystemVersion: nil, infoFeedURL: TipAppTrackTests.stableFeed, hasPublicKey: true)
    static let nightly = TipUpdateCheckTests.nightly
    static let tip = TipUpdateCheckTests.tip
    static let dev = UpdateBuildIdentity(bundleIdentifier: "com.cmuxterm.app.debug.asks-before-install", shortVersion: "0.1.0", build: "100",
                                         minimumSystemVersion: nil, infoFeedURL: "https://files-next.cmux.com/nightly-next/appcast-arm64.xml",
                                         hasPublicKey: false)
    static let channels = [stable, nightly, tip, dev]

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

    @Test func everyChannelAsksByDefault() {
        for track in UpdateTrack.allCases {
            #expect(!track.downloadsAutomaticallyByDefault, "\(track) downloads and installs by itself by default")
        }
        for identity in Self.channels {
            let (updater, _) = Self.make(identity)
            #expect(!updater.automaticUpdates && !updater.downloadsFoundUpdates,
                    "\(identity.track) (tip \(identity.isTipBuild)) downloads found updates by default")
        }
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

    /// Later (the Update Ready card's Hide): no relaunch; the quit installs it.
    @Test(arguments: UpdateAsksBeforeInstallTests.channels)
    func laterInstallsOnQuitWithoutARelaunch(identity: UpdateBuildIdentity) async throws {
        let (updater, effects) = Self.make(identity)
        updater.debugIndicatorPhase = .available(version: "2.0.0")
        updater.installClicked()
        updater.debugIndicatorPhase = .downloading(.starting)
        updater.debugIndicatorPhase = .ready(version: "2.0.0")
        #expect(updater.readyCard != nil)
        updater.closeUpdateCard(.hideVersion)
        #expect(updater.readyCard == nil, "Later left the Update Ready card")
        try await Task.sleep(for: .milliseconds(50))
        #expect(effects.installs == 0, "Later relaunched")
        #expect(updater.prepareForQuit() == .proceed, "the quit does not install the staged update")
        #expect(effects.cancels == 0, "the quit cancelled the staged update's installer")
    }

    /// The opt-in (`updates.downloadAutomatically` on): found updates download by themselves, a
    /// click on a found update (downloads deferred on a metered link) installs as one click, and an
    /// install nobody clicked takes #25904's background relaunch (the app quits, Sparkle installs,
    /// `open -g` reopens it behind).
    @Test(arguments: UpdateAsksBeforeInstallTests.channels)
    func theOptInDownloadsInstallsAndRelaunchesBehind(identity: UpdateBuildIdentity) async throws {
        let (updater, effects) = Self.make(identity, optIn: true)
        #expect(updater.downloadsFoundUpdates && updater.automaticUpdates, "\(identity.track): the opt-in does not download by itself")
        updater.debugIndicatorPhase = .available(version: "2.0.0")
        updater.installClicked()
        #expect(updater.flow.installRequested, "\(identity.track): with the opt-in the click asks again before the relaunch")
        updater.debugIndicatorPhase = .downloading(.starting)
        updater.debugIndicatorPhase = .ready(version: "2.0.0")
        #expect(await eventually { effects.installs == 1 }, "\(identity.track): the opted-in click did not install once staged")

        updater.frontmost = { UpdateFrontmostApp(isThisApp: false, pid: 7045, bundleID: "com.example.other") }
        updater.automaticInstallInFlight = true
        var reopensBehind = false
        updater.relaunchBehind = { _, _, _ in reopensBehind = true }
        #expect(updater.updaterQuitsForAutomaticInstall(build: "200") && reopensBehind,
                "\(identity.track): an automatic install did not take the background relaunch")
    }

    func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }
}
