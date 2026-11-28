import AppKit
@testable import CmuxNextApp
import CmuxNextPages
import CmuxNextSettings
@testable import CmuxNextSidebar
@testable import CmuxNextUpdater
import Foundation
import Testing

/// Leo 2026-11-03, on the sidebar's Downloading Update card: "idk chatgpt's seems to be just like a
/// one step "ok it's already downloaded you click this button to accept the button and restart" idk
/// if we wanna follow that too". A background download runs with no sidebar card (one the person
/// asked for shows its progress, Leo 2026-11-04); the staged update is the
/// one Restart to Update card, whose click installs and relaunches; the download's progress, its
/// Cancel and a failure's Try Again are Settings > Updates' App Update card.
@MainActor @Suite(.serialized) struct UpdateOneStepTests {
    static let mb: UInt64 = 1_000_000
    static let half = UpdateIndicatorPhase.downloading(.downloading(received: 125 * mb, expected: 250 * mb))

    static func make() -> (UpdaterService, UpdateAsksBeforeInstallTests.Effects) {
        UpdateAsksBeforeInstallTests.make(UpdateAsksBeforeInstallTests.nightly)
    }

    static func move(_ updater: UpdaterService, _ phases: [UpdateIndicatorPhase]) {
        for phase in phases {
            updater.debugIndicatorPhase = phase
            updater.syncFlowPhase()
        }
    }

    func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

    /// The App Update card's buttons, by action id.
    static func actions(_ json: JSONValue) -> [String] {
        json["actions"]?.arrayValue?.compactMap { $0["id"]?.stringValue } ?? []
    }

    /// Leo 2026-11-04: "there's no more updating downloading progress bar for some reason? after i
    /// download... it got removed for some reason". A download the person asked for shows its progress
    /// on the sidebar's notice card until it is staged.
    @Test func aDownloadThePersonAskedForShowsItsProgress() {
        let (updater, _) = Self.make()
        updater.send(.checkRequested)
        Self.move(updater, [.checking, .available(version: "2.0.0")])
        updater.performCardAction(.update)
        for case .downloading(let transfer) in [UpdateIndicatorPhase.downloading(.starting), Self.half, .downloading(.preparing(0.5))] {
            Self.move(updater, [.downloading(transfer)])
            #expect(updater.card == .downloading(transfer), "the sidebar shows no progress at \(transfer)")
            #expect(SidebarCardFeed.updateCard(updater) == nil, "the ready card shows before the update is staged")
        }
    }

    /// A download nobody asked for (a scheduled check's) stays quiet: no sidebar card until it is staged.
    @Test func aBackgroundDownloadShowsNoSidebarCard() {
        let (updater, _) = Self.make()
        Self.move(updater, [.checking, .downloading(.starting), Self.half])
        #expect(updater.card == nil, "a background download shows a sidebar card")
    }

    /// The Restart button takes the place of the download's card under the pointer: for a moment
    /// a click meant for that card does not restart cmux. Keys and VoiceOver still press it.
    @Test func theRestartButtonIgnoresAClickRightAfterTheCardAppears() throws {
        let (updater, _) = Self.make()
        Self.move(updater, [.checking, .downloading(.starting), Self.half, .ready(version: "2.0.0")])
        let card = try #require(SidebarCardFeed.updateCard(updater), "the staged update shows no card")
        let view = SidebarUpdateCardView(frame: NSRect(x: 0, y: 0, width: 216, height: 120))
        let shown = ProcessInfo.processInfo.systemUptime
        view.configure(card)
        #expect(view.button.ignoresPointer(at: shown + 0.5), "a click half a second after the card appeared restarts cmux")
        #expect(!view.button.ignoresPointer(at: shown + SidebarUpdateButton.appearGuard + 0.1), "the button ignores clicks for good")
        var sent = 0
        view.onInstall = { sent += 1 }
        view.button.press()
        #expect(sent == 1, "the guard also ignored a key or VoiceOver press")
    }

    @Test func theStagedUpdateIsOneRestartCardWhoseClickInstalls() async throws {
        let (updater, effects) = Self.make()
        Self.move(updater, [.checking, .downloading(.starting), Self.half, .ready(version: "2.0.0")])
        #expect(updater.card == nil, "a notice card shows beside the ready card")
        let card = try #require(SidebarCardFeed.updateCard(updater), "the staged update shows no card")
        #expect(card.buttonTitle == UpdaterStrings.restartToUpdate && card.isEnabled)

        // The card's one button sends installUpdate; SidebarCardFeed.handle runs installClicked.
        let view = SidebarUpdateCardView(frame: NSRect(x: 0, y: 0, width: 216, height: 120))
        view.configure(card)
        var sent = 0
        view.onInstall = { sent += 1; updater.installClicked() }
        view.button.onPress?()
        #expect(sent == 1)
        #expect(await eventually { effects.installs == 1 }, "Restart to Update did not install and relaunch")
    }

    @Test func settingsShowsTheDownloadsProgressAndItsCancel() throws {
        let (updater, _) = Self.make()
        #expect(updater.settingsStatus == nil)
        #expect(Self.actions(updater.settingsPageJSON) == ["check"], "an idle card offers no Check Now")

        Self.move(updater, [.checking, .downloading(.starting), Self.half])
        #expect(updater.settingsStatus == .card(.downloading(.downloading(received: 125 * Self.mb, expected: 250 * Self.mb))))
        let json = updater.settingsPageJSON
        #expect(json["phase"]?.stringValue == "downloading")
        #expect(json["status"]?.stringValue == UpdaterStrings.downloading)
        #expect(json["progress"]?.doubleValue == 0.5, "Settings shows no progress: \(json)")
        #expect(json["detail"]?.stringValue?.isEmpty == false, "Settings shows no bytes line")
        #expect(Self.actions(json) == ["cancel_download"])

        Self.move(updater, [.ready(version: "2.0.0")])
        let ready = updater.settingsPageJSON
        #expect(ready["phase"]?.stringValue == "ready")
        #expect(Self.actions(ready) == ["install"])
        #expect(ready["progress"] == nil)
    }

    @Test func aDownloadReSendsSettingsOnlyWhenItsPercentChanges() {
        let (updater, _) = Self.make()
        Self.move(updater, [.checking, .downloading(.downloading(received: 125 * Self.mb, expected: 250 * Self.mb))])
        let first = updater.settingsPageJSON
        Self.move(updater, [.downloading(.downloading(received: 125 * Self.mb + 300_000, expected: 250 * Self.mb))])
        #expect(updater.settingsPageJSON == first, "the bytes line changed inside one percent")
        Self.move(updater, [.downloading(.downloading(received: 128 * Self.mb, expected: 250 * Self.mb))])
        #expect(updater.settingsPageJSON != first, "a new percent did not show")
    }

    @Test func aBackgroundFailureShowsInSettingsWithTryAgain() {
        let (updater, _) = Self.make()
        // A scheduled check and download the person never asked for, then Sparkle's error.
        Self.move(updater, [.checking, Self.half, .note(.checkFailed)])
        #expect(updater.card == nil, "a background failure took the sidebar")
        #expect(updater.settingsStatus == .card(.note(.checkFailed)), "the failure shows nowhere")
        #expect(Self.actions(updater.settingsPageJSON) == ["retry"])
    }

    @Test func theCancelAndTheRestartGoThroughTheProvider() async throws {
        let (updater, effects) = Self.make()
        var cancels = 0
        updater.cancelDownloadNow = {
            cancels += 1
            updater.debugIndicatorPhase = .hidden
            return true
        }
        Self.move(updater, [.checking, Self.half])
        let provider = AppUpdatePageProvider(updater: updater)
        let click = PageCallContext(page: "cmux.settings", userGesture: true)
        _ = try await provider.call("cmux.settings.app_update.run", params: ["action": "cancel_download"], context: click)
        #expect(cancels == 1, "Cancel in Settings did not stop the download")

        Self.move(updater, [.checking, Self.half, .ready(version: "2.0.0")])
        let script = PageCallContext(page: "cmux.settings")
        await #expect(throws: PageError.self, "a call with no click restarted the app") {
            try await provider.call("cmux.settings.app_update.run", params: ["action": "install"], context: script)
        }
        _ = try await provider.call("cmux.settings.app_update.run", params: ["action": "install"], context: click)
        #expect(await eventually { effects.installs == 1 }, "Restart to Update in Settings did not install")
    }
}
