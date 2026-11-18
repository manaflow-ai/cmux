import AppKit
import CmuxNextActions
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextDesign
@testable import CmuxNextLayout
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// Leo 2026-11-07: "you have a thing that you already dragged, and yet you're playing the closed tab
/// animation. You should play no animation there." A tab that moves to another pane is not closed:
/// its source strip drops it with no close, and a pane the move empties leaves in the move's turn,
/// together with the tab showing in its new pane, not one daemon echo later after an empty pane.
@Suite(.serialized, .closesItsWindows)
@MainActor struct TabMoveDepartureTests {
    static func hasDisplay() -> Bool { !NSScreen.screens.isEmpty }

    /// Two panes side by side, one tab each.
    private static let sideBySide = LayoutNode.split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(1), b: .leaf(2))
    /// Three panes side by side, A (1), B (2) and C (3).
    private static let threeAcross = LayoutNode.split(id: nil, resourceID: nil, direction: .right, ratio: 0.33, a: .leaf(1),
                                                      b: .split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(2), b: .leaf(3)))

    /// One move of `TabMoves.move` in its turn, as it shows with no daemon (these tests have no
    /// connection, so `intendNow` would show nothing): the departure, the move's intent in the store,
    /// then the departure's close. No strip syncs in between, as in one action batch or two moves in
    /// one turn. Returns the move's outcome step and its intent's transaction.
    @discardableResult
    private func moveNow(_ tab: TabModel, from source: PaneController, to target: PaneController,
                         _ shown: PaneCloseControllerTests.Shown) -> (finish: TabMoves.Completion, transaction: ClientTransactionID) {
        let leave = TabMoves.depart(tab, into: target.pane, from: source, services: shown.services), transaction = ClientTransactionID.generate()
        shown.services.daemon.store.intend(.moveTab(surface: tab.surface, toPane: target.pane.handle, index: target.pane.tabs.count), transaction: transaction)
        return (leave(true) { _ in }, transaction)
    }

    /// A strip on screen with the structural `newTab` switch on: the case where a move used to play
    /// a close. Runs `body` with every override in place (synchronous: the overrides are process-wide).
    private func onScreen(_ model: TabStripModel, _ body: (TabStripView) throws -> Void) throws {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 600, height: 40), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        defer { window.closeAfterTest() }
        let strip = TabStripView(model: model)
        strip.frame = NSRect(x: 0, y: 0, width: 600, height: TabStripView.preferredHeight)
        window.contentView = strip
        window.orderFrontRegardless()
        try #require(window.screen != nil)
        strip.layoutSubtreeIfNeeded()
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let enabledAnimations = DesignSettings.shared.enabledAnimations
        DesignSettings.shared.enabledAnimations.insert(.newTab)
        defer { DesignSettings.shared.enabledAnimations = enabledAnimations }
        try #require(Motion.tabs.animatesMovement, "animation speed is off on this host")
        try body(strip)
    }

    /// The strip animates in a window on screen: with no screen nothing runs its springs.
    @Test(.enabled("a window with no screen applies its changes at once") { await Self.hasDisplay() })
    func aTabThatMovedAwayLeavesItsStripWithNoClose() throws {
        let model = TabStripModel(tabs: (0..<3).map { TabItem(id: TabID("tab\($0)"), title: "Tab \($0)") }, selectedID: TabID("tab0"))
        try onScreen(model) { strip in
            model.departures.insert(TabID("tab1"))
            model.tabs.remove(at: 1)
            strip.sync(fromModel: true)
            #expect(!strip.dying.contains(TabID("tab1")), "the moved tab played the close")
            #expect(strip.cells[TabID("tab1")] == nil, "the moved tab stayed in its old strip")
            #expect(model.departures.isEmpty, "the departure outlived its tab")

            // A real close still closes.
            model.tabs.removeLast()
            strip.sync(fromModel: true)
            #expect(strip.dying.contains(TabID("tab2")), "a close lost its tween")
        }
    }

    /// A group dragged to another pane takes its chip with it: neither the tabs nor the chip close.
    @Test(.enabled("a window with no screen applies its changes at once") { await Self.hasDisplay() })
    func aGroupThatMovedAwayTakesItsChipWithNoClose() throws {
        let tabs = [TabItem(id: "a", title: "a"), TabItem(id: "g1", title: "g1", groupID: "G"), TabItem(id: "g2", title: "g2", groupID: "G")]
        let model = TabStripModel(tabs: tabs, groups: [TabGroupItem(id: "G")], selectedID: "a")
        try onScreen(model) { strip in
            try #require(strip.groups.chips["G"] != nil)
            model.departures.formUnion(["g1", "g2"])
            model.tabs = [tabs[0]]
            model.groups = []
            strip.sync(fromModel: true)
            #expect(strip.dying.isEmpty, "closing: \(strip.dying.map(\.rawValue))")
            #expect(strip.groups.chips["G"] == nil, "the moved group's chip stayed")
        }
    }

    /// The right pane's only tab moves into the left pane (a drop on its strip, Move to Pane): the
    /// right pane leaves in the same turn, not after the daemon's tree.
    @Test func aPaneTheMoveEmptiesLeavesInTheMovesTurn() throws {
        let shown = try PaneCloseControllerTests.Shown(tree: PaneCloseControllerTests.splitTree(Self.sideBySide))
        defer { shown.end() }
        let source = try shown.controller(2), target = try shown.controller(1)
        let tab = try #require(source.pane.tabs.first)
        moveNow(tab, from: source, to: target, shown)
        #expect(shown.content.layoutModel.isClosing(source.layoutPaneID), "the emptied pane waited for the daemon's tree")
        #expect(shown.content.layoutModel.screens.first?.layout.contains(source.layoutPaneID) == false,
                "the emptied pane still shows")
        #expect(source.stripModel.departures.contains(StripTabID(tab.id)), "the source strip would close the moved tab")
        // The pane's close carries the tab to its destination in the focus topology: a tab that never
        // leaves it keeps its browser focus mode (the reducer drops modes of tabs it no longer holds).
        let topology = shown.content.focus.state.topology
        #expect(topology.pane(try shown.key(1))?.tab(tab.id) != nil, "the moved tab left the focus topology")
    }

    /// Router review F1: the topology the close publishes holds the moved tab, and a refused move
    /// shows the pane again with its tab, so a browser tab's focus mode survives both outcomes.
    @Test func aRefusedMoveBringsThePaneBackWithItsTab() throws {
        let shown = try PaneCloseControllerTests.Shown(tree: PaneCloseControllerTests.splitTree(Self.sideBySide))
        defer { shown.end() }
        let source = try shown.controller(2)
        let tab = try #require(source.pane.tabs.first)
        let (finish, transaction) = moveNow(tab, from: source, to: try shown.controller(1), shown)
        #expect(shown.content.layoutModel.isClosing(source.layoutPaneID), "the emptied pane waited for the daemon's tree")
        #expect(shown.content.focus.state.topology.allTabIDs.contains(tab.id), "the moved tab left the focus topology")
        shown.services.daemon.store.rejectIntent(transaction) // as `intendNow` does before its failure
        finish(false)
        #expect(!shown.content.layoutModel.isClosing(source.layoutPaneID), "a refused move kept the pane closed")
        #expect(!source.stripModel.departures.contains(StripTabID(tab.id)), "a refused move left the tab departing")
        #expect(shown.content.focus.state.topology.pane(try shown.key(2))?.tab(tab.id) != nil, "the tab did not come back to its pane")
    }

    /// A pane that keeps a tab stays; only its strip drops the moved one.
    @Test func aPaneThatKeepsATabStays() throws {
        let tree = PaneCloseControllerTests.splitTree(Self.sideBySide, tabs: [1: 1, 2: 2])
        let shown = try PaneCloseControllerTests.Shown(tree: tree)
        defer { shown.end() }
        let source = try shown.controller(2), target = try shown.controller(1)
        let tab = try #require(source.pane.tabs.first)
        moveNow(tab, from: source, to: target, shown)
        #expect(!shown.content.layoutModel.isClosing(source.layoutPaneID), "a pane with a tab left closed")
        #expect(source.stripModel.departures.contains(StripTabID(tab.id)))
    }

    /// With no daemon the move's intent never shows: the tab stays in its pane, so the pane stays
    /// too, rather than closing and coming back on the refusal.
    @Test func aMoveTheStoreDoesNotShowKeepsThePane() throws {
        let shown = try PaneCloseControllerTests.Shown(tree: PaneCloseControllerTests.splitTree(Self.sideBySide))
        defer { shown.end() }
        let source = try shown.controller(2), target = try shown.controller(1)
        let tab = try #require(source.pane.tabs.first)
        source.move(StripTabID(tab.id), toPane: target, index: 1)
        #expect(!shown.content.layoutModel.isClosing(source.layoutPaneID), "the pane left while the store still holds its tab")
    }

    /// Router review F1 (#37735): in one turn A's tab moves into B, then B's own tab into C. B's
    /// strip still shows only its own tab, but B holds A's tab: B stays, and A leaves.
    @Test func aPaneAnEarlierMoveFilledStays() throws {
        let shown = try PaneCloseControllerTests.Shown(tree: PaneCloseControllerTests.splitTree(Self.threeAcross))
        defer { shown.end() }
        let a = try shown.controller(1), b = try shown.controller(2), c = try shown.controller(3)
        let tabA = try #require(a.pane.tabs.first), tabB = try #require(b.pane.tabs.first)
        moveNow(tabA, from: a, to: b, shown)
        moveNow(tabB, from: b, to: c, shown)
        #expect(shown.content.layoutModel.isClosing(a.layoutPaneID), "the pane the first move emptied waited for the daemon's tree")
        #expect(!shown.content.layoutModel.isClosing(b.layoutPaneID), "the pane holding the first move's tab left")
        #expect(shown.content.layoutModel.screens.first?.layout.contains(b.layoutPaneID) == true, "the pane holding the first move's tab is hidden")
        #expect(shown.content.focus.state.topology.pane(try shown.key(2))?.tab(tabA.id) != nil, "the first move's tab left the focus topology")
    }

    /// The mirror: B's two tabs leave by two moves in one turn, one into A and one into C. The
    /// second empties B, so B leaves, and both tabs stay in the focus topology at their destinations.
    @Test func twoMovesThatEmptyAPaneCloseIt() throws {
        let shown = try PaneCloseControllerTests.Shown(tree: PaneCloseControllerTests.splitTree(Self.threeAcross, tabs: [2: 2]))
        defer { shown.end() }
        let a = try shown.controller(1), b = try shown.controller(2), c = try shown.controller(3)
        let first = b.pane.tabs[0], second = b.pane.tabs[1]
        moveNow(first, from: b, to: a, shown)
        #expect(!shown.content.layoutModel.isClosing(b.layoutPaneID), "a pane that keeps a tab left")
        moveNow(second, from: b, to: c, shown)
        #expect(shown.content.layoutModel.isClosing(b.layoutPaneID), "the pane the second move emptied waited for the daemon's tree")
        let topology = shown.content.focus.state.topology
        #expect(topology.pane(try shown.key(1))?.tab(first.id) != nil, "the first move's tab left the focus topology")
        #expect(topology.pane(try shown.key(3))?.tab(second.id) != nil, "the second move's tab left the focus topology")
    }

    /// Router review F1 at 55883d6c: a topology queued in the move's turn (a strip or tab change,
    /// `setNeedsTopology`) is built when the close reads the focus state. Built after the pane hid, it
    /// held neither the pane nor the moved tab (its new strip has not synced), so the tab left the
    /// topology. The moved tab stays, in its new pane, with its kind.
    @Test func aQueuedTopologyKeepsTheMovedTab() throws {
        let shown = try PaneCloseControllerTests.Shown(tree: PaneCloseControllerTests.splitTree(Self.sideBySide))
        defer { shown.end() }
        let source = try shown.controller(2), target = try shown.controller(1)
        let tab = try #require(source.pane.tabs.first)
        shown.content.setNeedsTopology()
        moveNow(tab, from: source, to: target, shown)
        #expect(shown.content.layoutModel.isClosing(source.layoutPaneID), "the emptied pane waited for the daemon's tree")
        let moved = shown.content.focus.state.topology.pane(try shown.key(1))?.tab(tab.id)
        #expect(moved != nil, "the moved tab left the focus topology")
        #expect(moved?.kind == .terminal, "the moved tab lost its kind")
    }

    /// Router review on #37735 at 3763c54d: a group dragged within its own pane, or a tab moved to the workspace it is
    /// already in, moves nothing out. Its tab is not departing, so the tab's later real close still plays. Run on a
    /// same-tree cmux-tui, where the strip showing the pane is found (`AppServices.paneController(for:)`).
    @Test(.enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"), .timeLimit(.minutes(3)),
          .enabled("a window with no screen applies its changes at once") { await Self.hasDisplay() }, arguments: [true, false])
    func aMoveThatStaysKeepsTheTabsLaterCloseTween(_ group: Bool) async throws {
        try await AppHarnessWindows.withApp { services, connection in
            let pane = try MoveToNewWindowTests.firstPane(services)
            let browser = try await MoveToNewWindowTests.browserTab(in: pane, services, connection), id = StripTabID(browser.id)
            let strip = try #require(services.paneController(for: pane), "no controller shows the pane").stripModel
            var moved: Bool?
            if group {
                #expect(services.registry.perform("tabGroup.create", invocation: MoveToNewWindowTests.on(.tab, browser.id)))
                try await PinnedPageTests.until({ services.daemon.store.tab(surface: browser.surface)?.tabGroup != nil })
                TabGroupMoves.move(try #require(browser.tabGroup), to: pane, index: 0, services: services, transaction: .generate()) { moved = $0 }
            } else {
                let workspace = try #require(services.daemon.store.workspace(containing: pane.handle))
                TabMoves.toWorkspace(browser, workspace: workspace, services: services) { moved = $0 }
            }
            #expect(!strip.departures.contains(id), "a \(group ? "group drag within its pane" : "move to its own workspace") marked its tab departing")
            try await PinnedPageTests.until({ moved != nil })
            #expect(!strip.departures.contains(id), "the stay's mark outlived its move")
            // A real close of the tab, on a strip showing what the move left: it plays its tween.
            let model = TabStripModel(tabs: strip.tabs, selectedID: strip.tabs.first { $0.id != id }?.id ?? id)
            model.departures = strip.departures
            try onScreen(model) { view in
                model.tabs.removeAll { $0.id == id }
                view.sync(fromModel: true)
                #expect(view.dying.contains(id), "the tab's real close after a move that stayed played no close")
            }
        }
    }

    // MARK: Review follow-ups on #37735 (F2 to F4)

    /// F2: a tab dragged past the tear-off distance leaves its strip in the hand-off's turn
    /// (`handOffDrag`: the tab goes to the pointer, `detachedID`, then a sync). It is under the
    /// pointer, not closed: it leaves with no close, and so it does when its move lands.
    @Test(.enabled("a window with no screen applies its changes at once") { await Self.hasDisplay() })
    func aTabHandedToADragLeavesWithNoClose() throws {
        let model = TabStripModel(tabs: (0..<3).map { TabItem(id: TabID("tab\($0)"), title: "Tab \($0)") }, selectedID: TabID("tab0"))
        try onScreen(model) { strip in
            strip.detachedID = TabID("tab1")
            strip.sync(fromModel: false)
            #expect(!strip.dying.contains(TabID("tab1")), "the tab handed to the drag played the close")
            #expect(strip.cells[TabID("tab1")] == nil, "the tab handed to the drag stayed in its strip")
            model.tabs.remove(at: 1)
            strip.sync(fromModel: true)
            #expect(strip.dying.isEmpty, "closing: \(strip.dying.map(\.rawValue))")
        }
    }

    /// F2 for a group: the group handed to a drag takes its members and its chip with no close.
    @Test(.enabled("a window with no screen applies its changes at once") { await Self.hasDisplay() })
    func aGroupHandedToADragLeavesWithNoClose() throws {
        let tabs = [TabItem(id: "a", title: "a"), TabItem(id: "g1", title: "g1", groupID: "G"), TabItem(id: "g2", title: "g2", groupID: "G")]
        let model = TabStripModel(tabs: tabs, groups: [TabGroupItem(id: "G")], selectedID: "a")
        try onScreen(model) { strip in
            try #require(strip.groups.chips["G"] != nil)
            strip.groups.detachedGroupID = "G"
            strip.sync(fromModel: false)
            #expect(strip.dying.isEmpty, "closing: \(strip.dying.map(\.rawValue))")
            #expect(strip.cells["g1"] == nil && strip.cells["g2"] == nil, "the group's tabs stayed in their strip")
        }
    }

    /// F4: Move Pane to Dock with no dock (and Move to New Window) moves the pane's other tabs into the new workspace
    /// (`TabMoves.join`) as Move to Workspace moves a tab (`TabMoves.depart`: no close). Router review F1 on #38342 at
    /// 7bbeb5ab: one move at a time, in order, and the join returns (its caller docks or opens the window) only once the
    /// daemon has made every move. Run on a same-tree cmux-tui.
    @Test(.enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"), .timeLimit(.minutes(3)))
    func joiningTabsIntoAWorkspaceMovesThemAsMoveToWorkspaceDoes() async throws {
        try await AppHarnessWindows.withApp { services, connection in
            let pane = try MoveToNewWindowTests.firstPane(services), store = services.daemon.store
            var tabs: [TabModel] = []
            for _ in 0..<3 { tabs.append(try await MoveToNewWindowTests.browserTab(in: pane, services, connection)) }
            // Made in the background (no focus), so the window keeps showing the pane.
            let created = try await connection.state.createWorkspace(name: "join", ephemeral: false, terminal: true, focus: false)
            try await PinnedPageTests.until({ store.workspaces.contains { $0.resourceID == created.workspaceID && $0.screens.contains { !$0.panes.isEmpty } } })
            let other = try #require(store.workspaces.first { $0.resourceID == created.workspaceID })
            await TabMoves.join(tabs[...], workspace: WorkspaceKey(rawValue: other.id), services: services)
            // The daemon's own tree as the join returns: every move made, in the join's order.
            let tree = try await connection.listWorkspaces()
            let landed = (tree.workspaces.first { $0.resourceID == created.workspaceID }?.screens ?? []).flatMap(\.panes).flatMap(\.tabs).map(\.surface)
            let joined = tabs.map(\.surface)
            #expect(landed.filter(joined.contains) == joined, "the join returned before its moves were made in order: \(landed) for \(joined)")
        }
    }

    /// Router review F1 on #37735 at 5d4fa325: the daemon refuses Home's pinned tab leaving its dock with `moved: false`, not an
    /// error. That move fails like any refused one: Home's pane shows again, its tab keeps no departure mark, and the tab stays.
    @Test(.enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"), .timeLimit(.minutes(3)))
    func aMoveTheDaemonAnswersNotMovedShowsThePaneAgain() async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            let (_, home) = try await HomeSplitKeysTests.showHome(services, connection)
            let dock = try #require(HomeSplitKeysTests.panes(home).first), page = try #require(dock.tabs.first)
            var opensTerminal = ActionInvocation(origin: .user)
            opensTerminal.opensTerminal = true
            #expect(services.registry.perform("splitRight", invocation: opensTerminal))
            try await PasswordManagerRouteTests.until({
                HomeSplitKeysTests.panes(home).count == 2
                    && HomeSplitKeysTests.panes(home).last?.tabs.first.map { !ProvisionalTab.isProvisional(surface: $0.surface) } == true
            }, report: { "\(HomeSplitKeysTests.panes(home).count) panes beside Home" })
            let right = try #require(HomeSplitKeysTests.panes(home).last)
            let controller = try #require(services.paneController(for: dock)), content = try #require(controller.workspace)
            var moved: Bool?
            TabMoves.move(page, to: right, index: 0, services: services) { moved = $0 }
            try await PasswordManagerRouteTests.until({ moved != nil }, report: { "the move never finished" })
            #expect(moved == false, "a move the daemon answered `moved: false` finished as done")
            #expect(!content.layoutModel.isClosing(controller.layoutPaneID), "Home's pane stayed hidden after the refused move")
            #expect(!controller.stripModel.departures.contains(StripTabID(page.id)), "the refused move's departure mark stayed")
            #expect(dock.tabs.contains { $0.surface == page.surface }, "Home's tab is not back in its pane")
        }
    }
}
