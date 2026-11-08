import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextTabs
import Foundation
import Testing

/// Lawrence 2026-11-08 (cmux-ad i5): "one more bug is behavior when closing a tab, it should always
/// focus the tab before it if it exists."
///
/// The rule (`FocusAfterClose.tab`, cmux-focus-core `close_focus::tab`): closing the selected tab
/// selects the visible tab immediately before it in its pane; only the first tab's close selects the
/// tab after it. Closing a tab that is not selected keeps the selection. Every entry point uses it:
/// the close button, middle-click, the tab menu, Cmd-W and the CLI's close (a daemon tree change), so
/// each case here runs the app's own action or strip intent against a same-tree cmux-tui daemon.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct TabCloseSelectsBeforeTests {
    /// One pane: its terminal tab, then `count` browser tabs. Returns the pane and the tab ids in strip order.
    static func pane(_ services: AppServices, _ connection: DaemonConnection, browsers count: Int) async throws -> (PaneController, [String], [String: SurfaceID]) {
        let store = services.daemon.store
        let content = try #require(services.windows.active?.workspaceContent)
        let model = try #require(store.workspaces.first?.screens.first?.panes.first)
        let pane = try #require(services.paneController(for: model))
        let terminal = try #require(model.tabs.first)
        var surfaces: [SurfaceID] = [terminal.surface]
        for index in 0..<count {
            let tab = try await connection.newFrontendBrowserTab(url: "https://example.com/\(index)", engine: .webkit,
                                                                 in: model.handle, activate: false)
            surfaces.append(tab.surface)
        }
        try await PinnedPageTests.until({ surfaces.allSatisfy { store.tab(surface: $0) != nil } })
        var ids: [String] = []
        var surfaceOf: [String: SurfaceID] = [:]
        for surface in surfaces {
            let id = try #require(store.tab(surface: surface)).id
            ids.append(id)
            surfaceOf[id] = surface
        }
        try await PinnedPageTests.until({ pane.orderedIDs.map(\.rawValue) == ids },
                                        report: { "the pane holds \(pane.orderedIDs.map(\.rawValue)), wanted \(ids)" })
        PaneHandlers.focus(pane.layoutPaneID, in: content)
        return (pane, ids, surfaceOf)
    }

    static func select(_ id: String, in pane: PaneController) async throws {
        pane.select(TabID(id))
        try await PinnedPageTests.until({ pane.stripModel.selectedID?.rawValue == id })
    }

    /// Waits until `closed` is gone and `pane` selects `selected`.
    static func expect(_ pane: PaneController, _ services: AppServices, closed: [String], selects selected: String,
                               _ what: String, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let store = services.daemon.store
        try await PinnedPageTests.until({ closed.allSatisfy { store.tab(id: $0) == nil } && pane.stripModel.selectedID?.rawValue == selected },
                                        report: { "\(what): the pane holds \(pane.orderedIDs.map(\.rawValue)), selects \(pane.stripModel.selectedID?.rawValue ?? "none"), wanted \(selected)" },
                                        sourceLocation: sourceLocation)
    }

    private static func cmdW(_ services: AppServices) -> Bool {
        services.registry.perform("closeTab", invocation: ActionInvocation(origin: .user))
    }

    /// The close button, the tab menu, the CLI and Cmd-W each select the tab before the closed one;
    /// an unselected close keeps the selection; a browser tab's close selects the terminal before it.
    @Test func everyEntryPointSelectsTheTabBefore() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let (pane, ids, surface) = try await Self.pane(services, connection, browsers: 4) // T b0 b1 b2 b3
            try await Self.select(ids[3], in: pane)
            pane.stripModel.send(.close(TabID(ids[3]), source: .mouse)) // the close button on b2
            try await Self.expect(pane, services, closed: [ids[3]], selects: ids[2], "the close button")
            pane.stripModel.send(.close(TabID(ids[4]), source: .contextMenu)) // the tab menu on b3, not selected
            try await Self.expect(pane, services, closed: [ids[4]], selects: ids[2], "an unselected close")
            try await connection.closeTab(try #require(surface[ids[2]])) // the CLI's close of the selected b1
            try await Self.expect(pane, services, closed: [ids[2]], selects: ids[1], "the CLI's close")
            #expect(Self.cmdW(services)) // Cmd-W on b0: the terminal before it
            try await Self.expect(pane, services, closed: [ids[1]], selects: ids[0], "Cmd-W")
        }
    }

    /// Only the first tab's close selects the tab after it; closing the first unpinned tab selects
    /// the last pinned tab before it.
    @Test func theFirstTabSelectsTheTabAfterAndTheFirstUnpinnedTheLastPinned() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let (pane, ids, surface) = try await Self.pane(services, connection, browsers: 3) // T b0 | b1 b2
            for id in ids.prefix(2) { try await connection.setTabPinned(try #require(surface[id]), true) }
            try await PinnedPageTests.until({ pane.stripModel.orderedTabs.prefix(2).allSatisfy(\.isPinned) && pane.orderedIDs.map(\.rawValue) == ids })
            try await Self.select(ids[2], in: pane)
            pane.stripModel.send(.close(TabID(ids[2]), source: .middleClick)) // the first unpinned tab
            try await Self.expect(pane, services, closed: [ids[2]], selects: ids[1], "the first unpinned tab")
            try await Self.select(ids[0], in: pane)
            pane.stripModel.send(.close(TabID(ids[0]), source: .contextMenu)) // the first tab
            try await Self.expect(pane, services, closed: [ids[0]], selects: ids[1], "the first tab")
        }
    }

    /// The tab before is selected also when it is in another group; a collapsed group's tabs are
    /// skipped to the nearest visible tab before.
    @Test func groupsGiveTheTabBeforeAndSkipCollapsedOnes() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let (pane, ids, surface) = try await Self.pane(services, connection, browsers: 4) // T [b0 b1] b2 b3
            let group = try #require(try await connection.createTabGroup(tabs: [surface[ids[1]], surface[ids[2]]].compactMap { $0 }).groupID)
            try await PinnedPageTests.until({ pane.stripModel.groups.count == 1 && pane.orderedIDs.map(\.rawValue) == ids })
            try await Self.select(ids[3], in: pane)
            pane.stripModel.send(.close(TabID(ids[3]), source: .mouse)) // b2: b1 in the group before it
            try await Self.expect(pane, services, closed: [ids[3]], selects: ids[2], "the tab before in another group")
            try await Self.select(ids[4], in: pane)
            try await connection.updateTabGroup(group, collapsed: true)
            try await PinnedPageTests.until({ pane.stripModel.groups.first?.isCollapsed == true })
            pane.stripModel.send(.close(TabID(ids[4]), source: .mouse)) // b3: the collapsed b0 b1 are skipped
            try await Self.expect(pane, services, closed: [ids[4]], selects: ids[0], "past a collapsed group")
        }
    }

    /// Close Tabs to the Right closing the selected tab selects the tab before it (the kept one);
    /// Close Other Tabs keeps the selected tab it keeps.
    @Test func closeToTheRightAndCloseOthersKeepTheRule() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let (pane, ids, _) = try await Self.pane(services, connection, browsers: 3) // T b0 b1 b2
            try await Self.select(ids[3], in: pane)
            pane.stripModel.send(.closeToRight(of: TabID(ids[1])))
            try await Self.expect(pane, services, closed: [ids[2], ids[3]], selects: ids[1], "Close Tabs to the Right")
            pane.stripModel.send(.closeOthers(keeping: TabID(ids[1])))
            try await Self.expect(pane, services, closed: [ids[0]], selects: ids[1], "Close Other Tabs")
        }
    }

    /// Rapid Cmd-W: each press closes the tab the close before it selected (the tab before), with no
    /// stale index: from b2 of T b0 b1 b2 b3, three presses close b2, b1 and b0 and leave T selected.
    @Test func rapidCmdWClosesTheTabsBeforeInTurn() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let (pane, ids, _) = try await Self.pane(services, connection, browsers: 4)
            try await Self.select(ids[3], in: pane)
            for _ in 0..<3 { #expect(Self.cmdW(services)) }
            try await Self.expect(pane, services, closed: [ids[3], ids[2], ids[1]], selects: ids[0], "three quick Cmd-W")
            #expect(services.daemon.store.tab(id: ids[4]) != nil, "a quick Cmd-W closed the tab after the selection")
        }
    }
}
