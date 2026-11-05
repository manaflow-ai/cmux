import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
@testable import CmuxNextUpdater
import Foundation
import Testing

/// Leo 2026-11-04, on the Codex app's Update available button: "codex having this update available
/// and then me clicking it enabling it to auto install and restart is... interesting. should we do
/// that?" `updates.oneClickInstall` (off by default) makes Update on a found update the only ask:
/// the download shows its progress, then cmux installs and relaunches with no Restart to Update
/// click. Off, the flow asks twice as before (``UpdateAsksBeforeInstallTests``). A button that just
/// showed under the pointer ignores a click for a moment, so a click meant for what was there never
/// starts an update that restarts cmux.
@MainActor @Suite(.serialized) struct UpdateOneClickInstallTests {
    static func make(oneClick: Bool) -> (UpdaterService, UpdateAsksBeforeInstallTests.Effects) {
        let (updater, effects) = UpdateAsksBeforeInstallTests.make(UpdateAsksBeforeInstallTests.nightly, optIn: false)
        updater.preferences = UpdatePreferences(oneClickInstall: oneClick)
        return (updater, effects)
    }

    func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

    @Test func offByDefault() {
        #expect(!UpdatePreferences.defaults.oneClickInstall, "one click restarts cmux by default")
    }

    /// The footer's Update Available: one click downloads with its progress, then installs and
    /// relaunches once staged; no Restart to Update click is needed.
    @Test func theFooterButtonsClickDownloadsThenInstallsAndRelaunches() async {
        let (updater, effects) = Self.make(oneClick: true)
        updater.debugIndicatorPhase = .checking
        updater.debugIndicatorPhase = .available(version: "2.0.0")
        let button = updater.availableButton
        #expect(button == UpdateAvailableButton(version: "2.0.0", restarts: true), "the footer button is \(String(describing: button))")
        #expect(button?.label == UpdaterStrings.updateAvailableRestartsNamed("2.0.0"), "the label does not say the click restarts")

        updater.downloadClicked()
        #expect(effects.downloads == 1, "Update did not download")
        #expect(updater.flow.installRequested, "Update did not hold the install")
        let half = UpdateTransfer(stage: .downloading, fraction: 0.5)
        updater.debugIndicatorPhase = .downloading(half)
        #expect(updater.card == .downloading(half), "the download shows no progress")
        #expect(effects.installs == 0, "it installed before the update was staged")

        updater.debugIndicatorPhase = .ready(version: "2.0.0")
        #expect(await eventually { effects.installs == 1 }, "the staged update waited for a second click")
    }

    /// Check for Updates, then the found update card's Update: the same one click.
    @Test func theNoticeCardsUpdateIsOneClickToo() async {
        let (updater, effects) = Self.make(oneClick: true)
        updater.send(.checkRequested)
        updater.debugIndicatorPhase = .checking
        updater.debugIndicatorPhase = .available(version: "2.0.0")
        updater.performCardAction(.update)
        #expect(effects.downloads == 1 && updater.flow.installRequested, "the card's Update did not download and hold the install")
        updater.debugIndicatorPhase = .downloading(.starting)
        updater.debugIndicatorPhase = .ready(version: "2.0.0")
        #expect(await eventually { effects.installs == 1 }, "the staged update waited for a second click")
    }

    /// Off (the default): the click downloads only, and the staged update asks before the relaunch.
    @Test func offTheClickStillOnlyDownloads() async throws {
        let (updater, effects) = Self.make(oneClick: false)
        updater.debugIndicatorPhase = .available(version: "2.0.0")
        #expect(updater.availableButton == UpdateAvailableButton(version: "2.0.0"))
        #expect(updater.availableButton?.label == UpdaterStrings.updateAvailableNamed("2.0.0"))
        updater.downloadClicked()
        #expect(effects.downloads == 1 && !updater.flow.installRequested, "off, Update also asked to relaunch")
        updater.debugIndicatorPhase = .downloading(.starting)
        updater.debugIndicatorPhase = .ready(version: "2.0.0")
        try await Task.sleep(for: .milliseconds(50))
        #expect(effects.installs == 0, "off, the staged update relaunched without asking")
        #expect(updater.readyCard != nil, "off, the staged update did not ask before the relaunch")
    }

    /// A late or repeated click (the download already runs) neither downloads again nor arms an install.
    @Test func aClickAfterTheFoundStepDoesNothing() {
        let (updater, effects) = Self.make(oneClick: true)
        updater.debugIndicatorPhase = .available(version: "2.0.0")
        updater.debugIndicatorPhase = .downloading(.starting)
        updater.downloadClicked()
        #expect(effects.downloads == 0 && !updater.flow.installRequested, "a late click armed the restart")
    }

    /// The footer's Update Available button just showed: a click on its way to what was there is
    /// ignored for a moment. Keys and VoiceOver still press it.
    @Test func theFooterButtonIgnoresAClickRightAfterItShows() {
        _ = NSApplication.shared
        let sidebar = SidebarView(model: SidebarModel(sections: []), design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        let shown = ProcessInfo.processInfo.systemUptime
        sidebar.showUpdateAvailable("Update Available")
        let button = sidebar.updateAvailableButton
        #expect(button.ignoresPointer(at: shown + 0.5), "a click half a second after the button showed starts the update")
        #expect(!button.ignoresPointer(at: shown + SidebarUpdateButton.appearGuard + 0.1), "the button ignores clicks for good")
        var pressed = 0
        button.onPress = { pressed += 1 }
        #expect(button.accessibilityPerformPress() && pressed == 1, "the guard also ignored a VoiceOver press")
    }

    /// The found update's card takes the slot of Checking…: its new buttons ignore a click for a moment.
    @Test func aNoticeCardsNewButtonsIgnoreAClickRightAfterTheyShow() throws {
        _ = NSApplication.shared
        let checking = SidebarNoticeCard(id: "update", title: "Checking for Updates…")
        let found = SidebarNoticeCard(id: "update", title: "Update Available",
                                      actions: [.init(id: "update", title: "Update", prominent: true), .init(id: "release_notes", title: "Release Notes")])
        let card = SidebarNoticeCardView(frame: NSRect(x: 0, y: 0, width: 216, height: SidebarNoticeCardView.height(for: found)))
        card.configure(checking)
        let shown = ProcessInfo.processInfo.systemUptime
        card.configure(found)
        let update = try #require(card.actionButtons.first, "the found update shows no Update button")
        #expect(update.ignoresPointer(at: shown + 0.5), "a click half a second after Update showed presses it")
        #expect(!update.ignoresPointer(at: shown + SidebarUpdateButton.appearGuard + 0.1), "Update ignores clicks for good")
    }
}
