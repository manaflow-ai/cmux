import AppKit
@testable import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextDesign
@testable import CmuxNextHibernation
@testable import CmuxNextSidebar
@testable import CmuxNextTabs
import Foundation
import Testing

typealias TabCaptureStripID = CmuxNextTabs.TabID

/// Lawrence 2026-10-28 (u14806): "a browser tab has a camera/microphone thing but idk which
/// tab/workspace it is, help me find it, and build a better ui for it too". A tab using the
/// camera or microphone shows a red camera or microphone in its speaker's place (Chrome's
/// recording indicator); its sidebar row shows one too and a click on it shows the tab; Stop,
/// Block and Show are commands in the palette, verbs of the CLI and tools of MCP.
@MainActor @Suite(.serialized) struct TabCaptureIndicatorTests {
    // MARK: What the engines' report maps to

    @Test func theStripAndTheRowMapTheTabsCapture() {
        var state = BrowserTabState()
        #expect(BrowserTabAudio.captureBadge(state) == nil)
        #expect(BrowserTabAudio.rowCapture(state) == nil)
        state.capture = .camera
        #expect(BrowserTabAudio.captureBadge(state) == .camera)
        state.capture = .microphone
        #expect(BrowserTabAudio.captureBadge(state) == .microphone)
        state.capture = [.camera, .microphone]
        #expect(BrowserTabAudio.captureBadge(state) == .cameraAndMicrophone)
        #expect(BrowserTabAudio.rowCapture(state) == SidebarWorkspaceCapture(camera: true, microphone: true))
    }

    /// A page that uses the camera or microphone never hibernates, even when it does not answer.
    @Test func aCapturingPageIsNeverDiscarded() {
        let tab = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://call.example.com")))
        #expect(!BrowserHibernation.unanswered(tab).capturing)
        tab.simulate(.captureChanged(.microphone))
        #expect(BrowserHibernation.unanswered(tab).capturing)
        #expect(BrowserHibernation.unanswered(tab).stopsWhenFrozen)
    }

    // MARK: The strip's red mark

    /// The tab shows a red mark in the speaker's place, which is no mute button: a click on it
    /// selects the tab, and never toggles its sound.
    @Test(arguments: [TabCapture.camera, .microphone, .cameraAndMicrophone])
    func aCapturingTabShowsARedMarkThatSelects(_ capture: TabCapture) throws {
        var tabs = (0..<3).map { TabItem(id: TabCaptureStripID("tab\($0)"), title: "A page with a long enough title \($0)") }
        tabs[1].capture = capture
        tabs[1].audio = .playing
        let model = TabStripModel(tabs: tabs, selectedID: TabCaptureStripID("tab0"))
        let strip = TabStripView(model: model)
        strip.dragsWindowFromEmptySpace = false
        strip.frame = NSRect(x: 0, y: 0, width: 700, height: TabStripView.preferredHeight)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        window.contentView = strip
        window.orderFrontRegardless()
        strip.layoutSubtreeIfNeeded()
        let cell = try #require(strip.cells[TabCaptureStripID("tab1")])
        let mark = try #require(cell.audioLayer, "a capturing tab shows no mark")
        #expect(mark.opacity > 0 && mark.contents != nil)
        #expect(cell.audioButtonRect == nil, "the red mark is a mute button")
        #expect(cell.accessibility.accessibilityLabel()?.contains(CmuxNextTabs.Strings.axCapture(capture)) == true)
        tabs[1].capture = nil
        model.tabs = tabs
        strip.layoutSubtreeIfNeeded()
        #expect(strip.cells[TabCaptureStripID("tab1")]?.audioButtonRect != nil, "the speaker did not come back")
    }

    // MARK: The sidebar row's red mark

    @Test func theRowMergesWhatItsTabsCapture() {
        #expect(SidebarWorkspaceCapture.merge([nil, nil]) == nil)
        #expect(SidebarWorkspaceCapture.merge([]) == nil)
        #expect(SidebarWorkspaceCapture.merge([nil, .init(camera: true, microphone: false), .init(camera: false, microphone: true)])
            == .init(camera: true, microphone: true))
    }

    /// The mapped row carries what its browser tabs capture (`SidebarMapping.PageFace.capture`).
    @Test func theMappedRowCarriesItsTabsCapture() throws {
        let store = DaemonStore()
        let pane = PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1, kind: .browser, url: "https://quiet.example"),
                                              TabSnapshot(surface: 2, kind: .browser, url: "https://call.example")])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])]))
        let workspace = try #require(store.workspaces.first)
        let row = SidebarMapping.shared.row(workspace, machine: .local, pageFace: { _, tab, _ in
            .init(capture: tab.url == "https://call.example" ? .init(camera: false, microphone: true) : nil)
        })
        #expect(row.capture == .init(camera: false, microphone: true))
        #expect(SidebarMapping.shared.row(workspace, machine: .local, pageFace: { _, _, _ in .init() }).capture == nil)
    }

    /// The row shows its red mark while a tab captures (always, not only on hover), and a click
    /// on it asks once to show that tab; a quiet workspace's row shows none.
    @Test func theRowShowsARedMarkThatShowsTheTab() throws {
        let call = WorkspaceID("ws-call"), quiet = WorkspaceID("ws-quiet")
        var callRow = SidebarWorkspace(id: call, title: "Voice Room", kind: .browser)
        callRow.capture = .init(camera: false, microphone: true)
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: [
            .workspace(callRow), .workspace(SidebarWorkspace(id: quiet, title: "Notes", kind: .terminal)),
        ])])
        var sent: [SidebarIntent] = []
        model.onIntent = { sent.append($0) }
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 400)
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        sidebar.list.rowViews.values.forEach { $0.layoutSubtreeIfNeeded() }
        let row = try #require(sidebar.list.rowViews[.workspace(call)] as? WorkspaceRowView)
        let silent = try #require(sidebar.list.rowViews[.workspace(quiet)] as? WorkspaceRowView)
        #expect(!row.captureButton.isHidden && row.captureButton.alphaValue > 0, "a capturing row shows no mark")
        #expect(row.captureButton.frame.width > 0 && row.bounds.contains(row.captureButton.frame))
        #expect(row.captureButton.icon == .sitePermissionMicrophone)
        #expect(row.captureButton.label == CmuxNextSidebar.Strings.capturingTab(.init(camera: false, microphone: true)))
        #expect(silent.captureButton.isHidden, "a quiet row shows a red mark")
        row.captureButton.performClick(nil)
        #expect(sent == [.showCapturingTab(call)], "\(sent)")
    }

    // MARK: Palette, CLI and MCP

    @Test(arguments: [("tab.stopMediaCapture", "tab stop-capture"), ("tab.blockMediaCapture", "tab block-capture"),
                      ("browser.showCapturingTab", "tab show-capturing")])
    func theCaptureActionsAreEverywhere(_ id: String, _ verb: String) throws {
        let descriptor = try #require(ActionCatalog.all.first { $0.id.rawValue == id }, "no action \(id)")
        #expect(descriptor.cliName == verb)
        #expect(descriptor.surfacePlan.cli?.isOffered == true, "\(id) is no CLI verb")
        #expect(descriptor.surfacePlan.mcp?.isOffered == true, "\(id) is no MCP tool")
        #expect(descriptor.isPaletteVisible, "\(id) is not in the palette")
    }

    @Test(arguments: ["tab.stopMediaCapture", "tab.blockMediaCapture"])
    func theCaptureRowsHaveTheirOwnMenuPosition(_ id: String) throws {
        let own = try #require(ActionSurfaceCatalog.placements[ActionID(stringLiteral: id)], "\(id) has no menu row")
        for row in own {
            let shared = ActionSurfaceCatalog.placements.filter { key, rows in
                key.rawValue != id && rows.contains { $0.context == row.context && $0.group == row.group && $0.rank == row.rank }
            }.map(\.key.rawValue)
            #expect(shared.isEmpty, "\(id) shares rank \(row.rank) with \(shared)")
        }
    }
}
