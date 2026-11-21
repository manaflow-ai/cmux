import AppKit
import CmuxNextDevices
@testable import CmuxNextDesign
@testable import CmuxNextMacScreen
import CmuxNextTestSupport
import CmuxScreenKit
import Foundation
import Testing

/// The viewer looks after #48677: look A is the default, an open viewer follows the setting, each look keeps its own
/// toolbar visibility, and the keyboard lands on the buttons on screen (the card's, or look B's strip's).
@MainActor @Suite(.serialized, .closesItsWindows)
struct MacScreenViewerLookFollowUpTests {
    private func pane(_ look: MacScreenViewerLook?, phase: MacScreenHubPhase = .idle) -> (MacScreenPane, MacScreenHubViewer) {
        let viewer = MacScreenHubViewer(deviceID: "0b6c1a2e-3d4f-4a5b-8c9d-aabbccddeeff") { nil }
        viewer.phase = phase
        let pane = MacScreenPane(hubDevice: viewer, name: "Studio MacBook Pro", preferences: ScreenPreferences(), viewerLook: look)
        pane.view.frame = CGRect(x: 0, y: 0, width: 1000, height: 640)
        pane.view.layoutSubtreeIfNeeded()
        return (pane, viewer)
    }

    @Test func lookAIsTheDefault() {
        #expect(MacScreenTunables.viewerLook.defaultValue == .a)
    }

    /// A pane with no fixed look reads the setting each time; a fixed look wins until it is cleared.
    @Test func theLookFollowsTheSettingUnlessFixed() {
        let (pane, _) = pane(nil)
        defer { pane.close() }
        #expect(pane.model.viewerLook == MacScreenTunables.viewerLook.value)
        pane.model.viewerLook = .c
        #expect(pane.model.viewerLook == .c)
        pane.model.viewerLookOverride = nil
        #expect(pane.model.viewerLook == MacScreenTunables.viewerLook.value)
    }

    /// Look C's pill floats only over a live picture: a layout in a state screen keeps it hidden.
    @Test func layoutKeepsLookCsPillHiddenOverAState() {
        let (pane, _) = pane(.c)
        defer { pane.close() }
        #expect(pane.model.card != nil)
        #expect(pane.view.chrome.toolbar.isHidden)
        pane.view.needsLayout = true
        pane.view.layoutSubtreeIfNeeded()
        #expect(pane.view.chrome.toolbar.isHidden)
    }

    /// Look A's faded toolbar stays hidden through layouts (clicks reach the picture) until it is shown again.
    @Test func layoutKeepsAnAutoHiddenToolbarHidden() {
        let (pane, _) = pane(.a)
        defer { pane.close() }
        let toolbar = pane.view.chrome.toolbar
        #expect(!toolbar.isHidden)
        toolbar.autoHidden = true
        pane.view.needsLayout = true
        pane.view.layoutSubtreeIfNeeded()
        #expect(toolbar.isHidden)
        toolbar.autoHidden = false
        #expect(!toolbar.isHidden)
    }

    /// Under look B the card is hidden: the keyboard goes to the strip's Full Control, a keyboard loop of its buttons.
    @Test func lookBFocusesTheStripsButtons() throws {
        let (pane, _) = pane(.b)
        defer { pane.close() }
        let bar = try #require(pane.view.chrome.statusStrip?.bar)
        let target = try #require(pane.focusTarget as? MacScreenButton)
        #expect(target.accessibilityIdentifier() == "macScreen.hub.connectFull")
        #expect(target.isDescendant(of: bar))
        #expect(target.takesKeyFocus)
        let view = try #require(target.nextKeyView as? MacScreenButton)
        #expect(view.accessibilityIdentifier() == "macScreen.hub.connectView")
        #expect(view.nextKeyView === target)
    }

    /// The tab asks the pane for its focus target each time: after the card changes it is the new card's button.
    @Test func theTabResolvesThePanesFocusTargetWhenAsked() async throws {
        let (pane, viewer) = pane(.current)
        let tab = MacScreenTab(key: "tab", record: MacScreenRecord(deviceID: "0b6c1a2e-3d4f-4a5b-8c9d-aabbccddeeff"))
        defer { tab.clear() }
        tab.install(pane)
        let first = pane.focusTarget
        #expect(tab.view.focusTarget === first)
        viewer.phase = .declined(.full)
        for _ in 0 ..< 200 where pane.focusTarget === first { await Task.yield() }
        #expect(pane.focusTarget !== first)
        #expect(tab.view.focusTarget === pane.focusTarget)
    }
}
