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

    /// A live pane as the gallery draws one: a streaming session at `scope` with a picture, laid out at `size`.
    private func livePane(_ look: MacScreenViewerLook, scope: SessionScope, size: CGSize = CGSize(width: 1280, height: 800)) async -> MacScreenPane {
        let viewer = MacScreenHubViewer(deviceID: "0b6c1a2e-3d4f-4a5b-8c9d-aabbccddeeff") { nil }
        viewer.phase = .streaming(sessionID: "follow-up", scope: scope)
        let pane = MacScreenPane(hubDevice: viewer, name: "Studio MacBook Pro", preferences: ScreenPreferences(), viewerLook: look)
        pane.model.hasFrame = true
        pane.session?.showPreviewState(phase: .connected, frameSize: CGSize(width: 2560, height: 1600))
        for _ in 0 ..< 100 { await Task.yield() }
        pane.view.frame = CGRect(origin: .zero, size: size)
        pane.view.needsLayout = true
        pane.view.layoutSubtreeIfNeeded()
        return pane
    }

    /// Look A's floating toolbar is as wide as its name, stats and controls need (the pane allowing): no label in it
    /// truncates at 1280 wide beside empty room, and it is wider than the controls' own width.
    @Test func lookAsToolbarFitsItsNameAndStats() async throws {
        let pane = await livePane(.a, scope: .full)
        defer { pane.close() }
        let toolbar = pane.view.chrome.toolbar
        #expect(!toolbar.isHidden)
        #expect(toolbar.frame.width >= toolbar.floatingWidth - 1 || toolbar.frame.width >= 1280 - 2 * MacScreenViewerLook.a.style.toolbarInset - 1)
        let labels = Self.labels(in: toolbar).filter { !$0.isHiddenOrHasHiddenAncestor }
        let name = try #require(labels.first { $0.stringValue == "Studio MacBook Pro" })
        let stats = try #require(labels.first { $0.accessibilityIdentifier() == "macScreen.stats" })
        #expect(!stats.stringValue.isEmpty)
        for label in [name, stats] {
            #expect(label.frame.width >= MacScreenToolbarView.textWidth(label) - 1, "\(label.stringValue) truncates")
        }
    }

    /// The stats line drops the codec and size first: the short line keeps the path, the rate and the round trip.
    @Test func theShortStatsLineDropsCodecAndSize() {
        let full = MacScreenToolbarView.statsLine(path: "direct", fps: 60, targetFps: 60, latencyMs: 12, encoding: "H.264",
                                                  frameSize: CGSize(width: 2560, height: 1600))
        let short = MacScreenToolbarView.statsLine(path: "direct", fps: 60, targetFps: 60, latencyMs: 12, encoding: "-", frameSize: .zero)
        #expect(full.contains("H.264") && full.contains("2560"))
        #expect(!short.contains("H.264") && !short.contains("2560"))
        #expect(short.contains("direct") && short.contains("12 ms"))
    }

    /// While this Mac controls the picture, only the pane's top edge brings look A's toolbar back: the remote menu bar
    /// under it takes the pointer. View Only keeps the wider band.
    @Test func controlKeepsTheRemoteMenuBarReachable() async {
        let control = await livePane(.a, scope: .full)
        defer { control.close() }
        #expect(control.view.chrome.overlay.revealZone.height == MacScreenLookA.controlRevealHeight)
        let view = await livePane(.a, scope: .view)
        defer { view.close() }
        #expect(view.view.chrome.overlay.revealZone.height >= MacScreenLookA.revealHeight)
    }

    private static func labels(in view: NSView) -> [NSTextField] {
        view.subviews.flatMap { subview -> [NSTextField] in
            if let label = subview as? NSTextField { return [label] }
            return labels(in: subview)
        }
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
