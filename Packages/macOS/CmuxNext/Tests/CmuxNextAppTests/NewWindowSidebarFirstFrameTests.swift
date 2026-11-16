import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextSidebar
import Foundation
import Testing

/// A new window's sidebar is complete in its first frame. The band above the list draws each item from the item's
/// info (its title, its icon, whether it is hidden). The window is ordered in at the end of the turn that makes its
/// sidebar, so each info has to be written in that turn: an info written by a task that starts later leaves a frame
/// where a pinned workspace shows its reference in the place of its name, and where a pin of a closed workspace with
/// no stored name (which draws nothing) is shown. These tests read the model with no suspension after the sidebar is
/// made, so no task has run. A band item with no info has no view: its place draws nothing, never the reference.
@MainActor @Suite(.serialized) struct NewWindowSidebarFirstFrameTests {
    static let session = "s-local"
    static let home = LayoutItem(id: LayoutItemID("itm_home"), ref: .builtIn(.home))
    static let page = LayoutItem(id: LayoutItemID("itm_page"), ref: .url("https://example.com"), label: "Example")
    static let open = LayoutItem(id: LayoutItemID("itm_open"), ref: .workspace("\(session):ws_open"))
    static let closed = LayoutItem(id: LayoutItemID("itm_closed"), ref: .workspace("\(session):ws_closed"))
    static let named = LayoutItem(id: LayoutItemID("itm_named"), ref: .workspace("\(session):ws_named"), label: "Docs")
    static let workspaceItems = [open, closed, named]

    static var document: SidebarLayoutDocument {
        SidebarLayoutDocument(sections: [
            LayoutSection(id: SidebarLayoutDocument.topSectionID, region: .top, look: .builtIn, items: [home, page]),
            SidebarLayoutDocument.pinnedSection(items: workspaceItems),
        ])
    }

    /// One window's sidebar over a session with one open workspace, made in the caller's turn. The band has a
    /// built-in item, a page item with a stored name, and three pinned workspaces: an open one, a closed one with no
    /// stored name and a closed one with a stored name.
    static func sidebar() throws -> SidebarBridge {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        // The band's layout, set before anything reads the service: no daemon and no document store write it later.
        let layout = SidebarLayoutService()
        layout.docLayout = document
        services.sidebarLayout = layout
        let store = services.machines.local.store
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        let tab = TabSnapshot(surface: 1, terminalResourceID: "term_open", name: "shell")
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [PaneSnapshot(id: 1, tabs: [tab])])
        store.apply(snapshot: DaemonTree(registryID: session, workspaces: [
            WorkspaceSnapshot(id: 1, key: WorkspaceKey(rawValue: "k-open"), resourceID: "ws_open", name: "Build", screens: [screen]),
        ]))
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"first-frame","workspace_key":"first-frame-home"}"#.utf8))
        let state = WindowState(record: record)
        services.windows.registry.provisional[state.id] = ["k-open"]
        return SidebarBridge(services: services, state: state)
    }

    @Test func eachBandItemHasItsInfoInTheTurnThatMakesTheSidebar() throws {
        let bridge = try Self.sidebar()
        defer { bridge.teardown() }
        let items = bridge.model.layout.sections.flatMap(\.items)
        try #require(Set(items.map(\.id)) == Set(Self.document.sections.flatMap(\.items).map(\.id)),
                     "the fixture is wrong: the band's layout is not the document that the test set")
        let infos = bridge.model.itemInfo
        for item in items {
            #expect(infos[item.id] != nil, "\(item.id.rawValue) has no info in the turn that makes the sidebar")
        }
    }

    @Test func noPinnedWorkspaceShowsItsReferenceInThatTurn() throws {
        let bridge = try Self.sidebar()
        defer { bridge.teardown() }
        let infos = bridge.model.itemInfo
        for item in Self.workspaceItems {
            // No info: the view has nothing to draw but the reference.
            let info = try #require(infos[item.id], "\(item.id.rawValue) has no info in the turn that makes the sidebar")
            #expect(info.isHidden || info.title != item.ref.value, "\(item.id.rawValue) is drawn with its reference as its title")
        }
        let open = try #require(infos[Self.open.id], "the open workspace's pin has no info")
        #expect(open.workspaceRow != nil, "the open workspace's pin is not drawn from its workspace")
        #expect(!open.isMissing && !open.isHidden)
        let named = try #require(infos[Self.named.id], "the closed pin with a stored name has no info")
        #expect(named.title == "Docs")
        #expect(named.isMissing && !named.isHidden)
    }

    @Test func aPinOfAClosedWorkspaceWithNoNameIsHiddenInThatTurn() throws {
        let bridge = try Self.sidebar()
        defer { bridge.teardown() }
        #expect(bridge.model.itemInfo[Self.closed.id]?.isHidden == true,
                "the closed pin with no stored name is not hidden in the turn that makes the sidebar")
        // What the band reads to leave an item out (`SidebarView.updateBands`).
        #expect(bridge.model.resolvedItemInfo.filter(\.value.isHidden).keys.contains(Self.closed.id))
    }

    @Test func aBandItemWithNoInfoHasNoView() throws {
        let region = SidebarRegionView(region: .top)
        region.frame = NSRect(x: 0, y: 0, width: 240, height: 200)
        let section = LayoutSection(id: SidebarLayoutDocument.topSectionID, region: .top, look: .builtIn, items: [Self.open])
        func content(_ infos: [LayoutItemID: SidebarItemInfo]) -> SidebarRegionView.Content {
            SidebarRegionView.Content(sections: [section], infos: infos, collapsed: [], look: SidebarSectionTunables.currentLook,
                                      metrics: .standard, drawsLines: false)
        }
        // The control: with its info the item has a view, drawn from the info.
        region.update(content([Self.open.id: SidebarItemInfo(title: "Build", symbol: "textformat")]), width: 240)
        let drawn = try #require(region.itemView(Self.open.id), "the fixture is wrong: the band draws no view for an item with an info")
        #expect(drawn.info.title == "Build")
        // The info is gone: so is the view. The band never draws an item from its reference.
        region.update(content([:]), width: 240)
        let left = region.itemView(Self.open.id)
        #expect(left == nil, "an item with no info is drawn with the title \(left?.info.title ?? "")")
    }
}
