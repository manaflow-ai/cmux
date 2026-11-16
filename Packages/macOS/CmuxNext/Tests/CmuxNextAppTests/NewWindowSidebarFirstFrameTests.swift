import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextLayout
@testable import CmuxNextSidebar
import Foundation
import Observation
import Testing

/// A new window's band items have their infos in the model before the window is ordered in. The band above the list
/// draws each item from the item's info (its title, its icon, whether it is hidden). The window is ordered in at the
/// end of the turn that makes its sidebar, so each info has to be written in that turn: with an info written by a task
/// that starts later, the model has no info for that hop, and an item with no info draws from its fallback
/// (`SidebarItemInfo.fallback(for:)`), where the pin of an open workspace with no stored name is not there and a
/// built-in has no badge. These tests read the model with no suspension after the sidebar is made, so no task has
/// run. No test draws a frame. A page item draws under the label stored with it: the app writes no info for it.
@MainActor @Suite(.serialized) struct NewWindowSidebarFirstFrameTests {
    static let session = "s-local"
    static let home = LayoutItem(id: LayoutItemID("itm_home"), ref: .builtIn(.home))
    static let page = LayoutItem(id: LayoutItemID("itm_page"), ref: .url("https://example.com"), label: "Example")
    static let open = LayoutItem(id: LayoutItemID("itm_open"), ref: .workspace("\(session):ws_open"))
    static let closed = LayoutItem(id: LayoutItemID("itm_closed"), ref: .workspace("\(session):ws_closed"))
    static let named = LayoutItem(id: LayoutItemID("itm_named"), ref: .workspace("\(session):ws_named"), label: "Docs")
    static let workspaceItems = [open, closed, named]

    static var document: SidebarLayoutDocument { document(pins: workspaceItems) }

    static func document(pins: [LayoutItem]) -> SidebarLayoutDocument {
        SidebarLayoutDocument(sections: [
            LayoutSection(id: SidebarLayoutDocument.topSectionID, region: .top, look: .builtIn, items: [home, page]),
            SidebarLayoutDocument.pinnedSection(items: pins),
        ])
    }

    /// The app over a session with one open workspace. The band has a built-in item, a page item with a stored name,
    /// and three pinned workspaces: an open one, a closed one with no stored name and a closed one with a stored name.
    static func app() throws -> AppServices {
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
        store.apply(snapshot: tree(name: "Build"))
        return services
    }

    /// The session's tree: the one open workspace, under `name`.
    static func tree(name: String) -> DaemonTree {
        let tab = TabSnapshot(surface: 1, terminalResourceID: "term_open", name: "shell")
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [PaneSnapshot(id: 1, tabs: [tab])])
        return DaemonTree(registryID: session, workspaces: [
            WorkspaceSnapshot(id: 1, key: WorkspaceKey(rawValue: "k-open"), resourceID: "ws_open", name: name, screens: [screen]),
        ])
    }

    /// One window's sidebar over that app, made in the caller's turn.
    static func sidebar() throws -> SidebarBridge {
        let services = try app()
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
        for item in items where item.id != Self.page.id {
            #expect(infos[item.id] != nil, "\(item.id.rawValue) has no info in the turn that makes the sidebar")
        }
        #expect(SidebarFirstFrame(bridge.model).faults.isEmpty)
    }

    @Test func noPinnedWorkspaceShowsItsReferenceInThatTurn() throws {
        let bridge = try Self.sidebar()
        defer { bridge.teardown() }
        let infos = bridge.model.itemInfo
        for item in Self.workspaceItems {
            // No info: the view draws the item from its fallback, not from its workspace.
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
        // What the band reads to leave an item out (`SidebarView.updateBands`); the fallback rule gives it with no info too.
        #expect(SidebarItemInfo.hiddenItems(in: bridge.model.layout.sections, infos: bridge.model.resolvedItemInfo).contains(Self.closed.id))
    }

    @Test func theCheckNamesEachItemWithNoInfoAndTheDesignedStates() throws {
        let bridge = try Self.sidebar()
        defer { bridge.teardown() }
        let frame = SidebarFirstFrame(bridge.model)
        #expect(frame.isComplete)
        // The closed pin with a stored name is dimmed under it; the page item draws under its stored label.
        #expect(frame.designedStates == Set<SidebarFirstFrame.DesignedState>([.closedPin, .storedLabel]))
        // With no info at all: each item that the app describes is a fault, the page item is not.
        let empty = SidebarFirstFrame(layout: bridge.model.layout, infos: [:], rows: [.live, .placeholder, .stale, .creating])
        #expect(!empty.isComplete)
        #expect(Set(empty.faults.map(\.id)) == Set([Self.home.id] + Self.workspaceItems.map(\.id)))
        #expect(empty.designedStates == Set<SidebarFirstFrame.DesignedState>([.loadingRow, .savedRow, .storedLabel]))
    }

    @Test func completeFirstFrameRunsThePassWhenAnInfoIsNotThere() throws {
        let bridge = try Self.sidebar()
        defer { bridge.teardown() }
        let pass = try #require(bridge.sectionsPass, "the sidebar has no pass for its band items")
        bridge.model.itemInfo = [:]
        // The method that the window manager's `present` calls.
        pass.completeFirstFrame()
        #expect(SidebarFirstFrame(bridge.model).isComplete)
        #expect(bridge.model.itemInfo[Self.open.id]?.workspaceRow != nil)
    }

    /// The window manager's `present` writes the values before its order-in. The window is a real one that is never
    /// ordered in (`ordersWindowsIn`); the test empties the values after the window is made, so only this call of
    /// `present` can write them again.
    @Test func presentWritesEachBandItemsInfoBeforeTheOrderIn() throws {
        let services = try Self.app()
        services.windows.ordersWindowsIn = false
        let controller = services.windows.makeController(for: WindowRegistry.Window(id: "first-frame-present"))
        defer { controller.teardown(); controller.window?.close() }
        let model = controller.sidebar.model
        try #require(model.layout.item(Self.home.id) != nil, "the fixture is wrong: the window's band does not list the item that the test set")
        model.itemInfo = [:]
        services.windows.present(controller)
        #expect(SidebarFirstFrame(model).isComplete, "present left band items with no info: \(SidebarFirstFrame(model).faults.map(\.id.rawValue))")
        #expect(model.itemInfo[Self.home.id] != nil)
    }

    /// After the first write the pass's task follows a change of the store: this test runs no pass itself. Its wait
    /// is the model's own change (Observation): one call reads the title and arms the wait, so a write between the two
    /// is not lost. The time limit is the bound: a change that the task does not write ends the test red, and the
    /// cancel check ends the loop then (a cancelled wait returns at once).
    @Test(.timeLimit(.minutes(1))) func theTaskWritesALaterChangeOfTheStore() async throws {
        let bridge = try Self.sidebar()
        defer { bridge.teardown() }
        let model = bridge.model
        try #require(model.itemInfo[Self.open.id]?.title == "Build", "the fixture is wrong: the open workspace's pin does not draw its workspace's name")
        bridge.services.machines.local.store.apply(snapshot: Self.tree(name: "Ship"))
        #expect(model.itemInfo[Self.open.id]?.title == "Build", "the title changed in the turn of the store's change: the wait below proves nothing")
        var title: String?
        while title != "Ship" {
            try Task.checkCancellation()
            let (changes, change) = AsyncStream<Void>.makeStream()
            title = withObservationTracking { model.itemInfo[Self.open.id]?.title } onChange: { change.yield(); change.finish() }
            if title != "Ship" { for await _ in changes { break } }
        }
        #expect(SidebarFirstFrame(model).isComplete)
    }

    @Test func aNewPinHasItsInfoInTheTurnThatShowsIt() throws {
        let bridge = try Self.sidebar()
        defer { bridge.teardown() }
        let added = LayoutItem(id: LayoutItemID("itm_added"), ref: .workspace("\(Self.session):ws_added"), label: "Notes")
        bridge.services.sidebarLayout.docLayout = Self.document(pins: Self.workspaceItems + [added])
        // The rows pass, run in this turn: it writes the band's layout with the new pin.
        bridge.sameTurn.syncNow(rows: true)
        try #require(bridge.model.layout.item(added.id) != nil, "the fixture is wrong: the rows pass did not write the band's layout")
        #expect(bridge.model.itemInfo[added.id]?.title == "Notes", "the new pin has no info in the turn that shows it")
        #expect(SidebarFirstFrame(bridge.model).isComplete)
    }

    @Test func anItemTheBandStillListsKeepsItsInfo() throws {
        let bridge = try Self.sidebar()
        defer { bridge.teardown() }
        let pass = try #require(bridge.sectionsPass, "the sidebar has no pass for its band items")
        // The pin leaves the stored layout. The band's layout has it until the rows pass runs: its info stays.
        bridge.services.sidebarLayout.docLayout = Self.document(pins: [Self.open, Self.closed])
        pass.run()
        try #require(bridge.model.layout.item(Self.named.id) != nil, "the fixture is wrong: the band's layout changed with no rows pass")
        #expect(bridge.model.itemInfo[Self.named.id]?.title == "Docs")
        // The rows pass takes the pin out of the band; the next pass drops its info.
        bridge.sameTurn.syncNow(rows: true)
        try #require(bridge.model.layout.item(Self.named.id) == nil, "the fixture is wrong: the rows pass kept the pin in the band")
        pass.run()
        #expect(bridge.model.itemInfo[Self.named.id] == nil)
    }
}
