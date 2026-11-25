import AppKit
import CmuxNextActions
import CmuxNextDevices
@testable import CmuxNextMacScreen
import CmuxNextWakeups
import Foundation
import Testing

/// The viewer toolbar's controls as palette rows (`macScreen.viewOnly` … `macScreen.reconnect`,
/// `macScreen.stopAllViewing`): each runs the handler its toolbar control runs, where the toolbar
/// offers it. The catalog rows themselves are checked in Rust (cmux-action-catalog's
/// screen_sharing_palette.rs), since this suite reads the pinned catalog.
@MainActor @Suite(.serialized)
struct MacScreenViewerControlTests {
    private let deviceA = "0b6c1a2e-3d4f-4a5b-8c9d-aabbccddeeff"
    private let deviceB = "5d1e2f3a-4b5c-4d6e-8f70-112233445566"

    private func pages() -> MacScreenPages {
        let file = FileManager.default.temporaryDirectory.appending(path: "viewer-controls-\(UUID().uuidString)/mac-screen.json")
        return MacScreenPages(store: MacScreenStore(file: file), work: BackgroundWork())
    }

    private func pane(_ key: String, device: String, in pages: MacScreenPages) throws -> MacScreenPane {
        pages.prepare(key, record: MacScreenRecord(deviceID: device), byPerson: false)
        _ = pages.makeView(for: key)
        return try #require(pages.tab(key)?.pane)
    }

    @Test func eachControlRunsItsToolbarHandler() {
        var ran: [String] = []
        let actions = MacScreenChromeActions()
        actions.requestScope = { ran.append("scope:\($0.rawValue)") }
        actions.fullScreen = { ran.append("fullScreen") }
        actions.sendKeys = { ran.append("keys:\($0.id)") }
        actions.connect = { ran.append("connect") }
        for control in MacScreenViewerControl.allCases { control.run(actions) }
        #expect(ran == ["scope:\(SessionScope.view.rawValue)", "scope:\(SessionScope.full.rawValue)", "fullScreen",
                        "keys:switchApp", "keys:spotlight", "connect"])
        #expect(Set(MacScreenViewerControl.allCases.map(\.actionID)).count == MacScreenViewerControl.allCases.count)
        for control in [MacScreenViewerControl.sendSwitchApp, .sendSpotlight] {
            #expect(MacScreenShortcut.all.contains { $0.id == control.shortcutID }, "\(control) names no Send Keys item")
        }
    }

    /// Available where the toolbar offers the control: the access choice it is not on, Full Screen while streaming,
    /// Reconnect where the card offers it; no Screen Sharing tab refuses every one.
    @Test func eachControlIsAvailableWhereTheToolbarOffersIt() throws {
        let pages = pages()
        let pane = try pane("a", device: deviceA, in: pages)
        let viewer = try #require(pane.model.hub)
        for control in MacScreenViewerControl.allCases { #expect(control.unavailableReason(nil) != nil, "\(control)") }

        viewer.phase = .streaming(sessionID: "s1", scope: .view)
        #expect(MacScreenViewerControl.viewOnly.unavailableReason(pane.model) != nil, "already View Only")
        #expect(MacScreenViewerControl.fullControl.unavailableReason(pane.model) == nil)
        #expect(MacScreenViewerControl.fullScreen.unavailableReason(pane.model) == nil)
        #expect(MacScreenViewerControl.sendSwitchApp.unavailableReason(pane.model) != nil, "no picture yet")

        viewer.phase = .streaming(sessionID: "s1", scope: .full)
        #expect(MacScreenViewerControl.viewOnly.unavailableReason(pane.model) == nil)
        #expect(MacScreenViewerControl.fullControl.unavailableReason(pane.model) != nil, "already Full Control")

        viewer.phase = .ended(reason: MacScreenHubReason.viewerDisconnected.rawValue)
        #expect(MacScreenViewerControl.reconnect.unavailableReason(pane.model) == nil)
        for control in [MacScreenViewerControl.viewOnly, .fullControl, .fullScreen, .sendSwitchApp, .sendSpotlight] {
            #expect(control.unavailableReason(pane.model) != nil, "\(control) on an ended session")
        }
        viewer.phase = .ended(reason: "device_removed:viewer")
        #expect(MacScreenViewerControl.reconnect.unavailableReason(pane.model) != nil, "the device left")
        pages.tabClosed("a")
    }

    /// The controls act on the targeted tab in any phase (Reconnect runs on an ended one); Stop Viewing keeps its rule.
    @Test func theControlsTargetTheTabInAnyPhase() throws {
        let pages = pages()
        let pane = try pane("a", device: deviceA, in: pages)
        let actions = MacScreenActions(pages: pages, selectedTab: { "a" }, providerKey: { id, _ in id },
                                       open: { _, _, _ in }, refusal: { _ in })
        pane.model.hub?.phase = .ended(reason: MacScreenHubReason.viewerDisconnected.rawValue)
        #expect(actions.screenTab(ActionInvocation()) === pane, "the selected tab")
        #expect(actions.screenTab(ActionInvocation(target: ActionTargetRef(kind: .tab, id: "other"))) == nil)
        #expect(actions.viewer(ActionInvocation()) == nil, "Stop Viewing needs a session")
        #expect(actions.unavailableReason(.reconnect, ActionInvocation()) == nil)

        pane.model.hub?.phase = .streaming(sessionID: "s1", scope: .view)
        #expect(actions.unavailableReason(.fullControl, ActionInvocation()) == nil)
        #expect(actions.unavailableReason(.fullScreen, ActionInvocation()) != nil, "the tab is in no window")
        pages.tabClosed("a")
    }

    /// Stop Viewing All Shared Screens ends every tab that asks, waits or streams, and only those.
    @Test func stopAllViewingEndsEveryViewingTab() throws {
        let pages = pages()
        let streaming = try pane("a", device: deviceA, in: pages)
        let ended = try pane("b", device: deviceB, in: pages)
        streaming.model.hub?.phase = .streaming(sessionID: "s1", scope: .view)
        ended.model.hub?.phase = .ended(reason: MacScreenHubReason.viewerDisconnected.rawValue)
        #expect(pages.viewingPanes.map(ObjectIdentifier.init) == [ObjectIdentifier(streaming)])
        for pane in pages.viewingPanes { pane.disconnectByPerson() }
        #expect(pages.viewingPanes.isEmpty)
        #expect(streaming.model.hub?.phase == .ended(reason: MacScreenHubReason.viewerDisconnected.rawValue))
        pages.tabClosed("a")
        pages.tabClosed("b")
    }
}
