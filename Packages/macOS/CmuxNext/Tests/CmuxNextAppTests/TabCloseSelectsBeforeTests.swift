import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextTabs
import Foundation
import Testing

/// Lawrence 2026-11-08 (cmux-ad i5): "one more bug is behavior when closing a tab, it should always
/// focus the tab before it if it exists."
///
/// That rule (#38316, #38328, #38419) is REPLACED by the one close-selection rule
/// (/work/wt/handoff/tasks/close-selection-rule.md; Lawrence 2026-11-10: "tabs also follow Chrome's
/// rule"), and these cases are changed to it: closing the selected tab selects a tab of its opener
/// family, else the NEXT visible tab of its pane, and the previous one only when it was the last.
/// The tabs here are made by the socket, so none has an opener (R2): the pick is by position (R1
/// rank 4; the opener rows are in `TabCloseSelectionTests`). Closing a tab that is not selected
/// keeps the selection (R0). Every entry point uses it: the close button, middle-click, the tab
/// menu, Cmd-W and the CLI's close (a daemon tree change), so each case here runs the app's own
/// action or strip intent against a same-tree cmux-tui daemon. The suite keeps its name: other
/// suites use its helpers.
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

    /// The close button, the CLI and Cmd-W each select the next tab, and the tab before only at the
    /// end of the strip; an unselected close keeps the selection (close-selection-rule.md R0, R1).
    @Test func everyEntryPointSelectsTheNextTab() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let (pane, ids, surface) = try await Self.pane(services, connection, browsers: 4) // T b0 b1 b2 b3
            try await Self.select(ids[1], in: pane)
            pane.stripModel.send(.close(TabID(ids[1]), source: .mouse)) // the close button on b0
            try await Self.expect(pane, services, closed: [ids[1]], selects: ids[2], "the close button")
            pane.stripModel.send(.close(TabID(ids[4]), source: .contextMenu)) // the tab menu on b3, not selected
            try await Self.expect(pane, services, closed: [ids[4]], selects: ids[2], "an unselected close")
            try await connection.closeTab(try #require(surface[ids[2]])) // the CLI's close of the selected b1
            try await Self.expect(pane, services, closed: [ids[2]], selects: ids[3], "the CLI's close")
            #expect(Self.cmdW(services)) // Cmd-W on b2, now the last tab: the terminal before it
            try await Self.expect(pane, services, closed: [ids[3]], selects: ids[0], "Cmd-W on the last tab")
        }
    }

    /// Pinned tabs follow the same rule (close-selection-rule.md R1): the first unpinned tab's close
    /// selects the tab after it, not the last pinned tab; the first tab's close selects the tab after it.
    @Test func pinnedTabsFollowTheSameRule() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let (pane, ids, surface) = try await Self.pane(services, connection, browsers: 3) // T b0 | b1 b2
            for id in ids.prefix(2) { try await connection.setTabPinned(try #require(surface[id]), true) }
            try await PinnedPageTests.until({ pane.stripModel.orderedTabs.prefix(2).allSatisfy(\.isPinned) && pane.orderedIDs.map(\.rawValue) == ids })
            try await Self.select(ids[2], in: pane)
            pane.stripModel.send(.close(TabID(ids[2]), source: .middleClick)) // the first unpinned tab
            try await Self.expect(pane, services, closed: [ids[2]], selects: ids[3], "the first unpinned tab")
            pane.stripModel.send(.close(TabID(ids[3]), source: .mouse)) // the last tab: pinned b0 before it
            try await Self.expect(pane, services, closed: [ids[3]], selects: ids[1], "the last tab")
            try await Self.select(ids[0], in: pane)
            pane.stripModel.send(.close(TabID(ids[0]), source: .contextMenu)) // the first tab
            try await Self.expect(pane, services, closed: [ids[0]], selects: ids[1], "the first tab")
        }
    }

    /// A group's edge does not change the pick (close-selection-rule.md, DECISION 14:20Z: no group
    /// preference): the group's last tab selects the tab after the group. A collapsed group's tabs
    /// are skipped to the next visible tab.
    @Test func groupsGiveTheNextTabAndSkipCollapsedOnes() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let (pane, ids, surface) = try await Self.pane(services, connection, browsers: 6) // T b0 [b1 b2 b3] b4 b5
            let group = try #require(try await connection.createTabGroup(tabs: [surface[ids[2]], surface[ids[3]], surface[ids[4]]].compactMap { $0 }).groupID)
            try await PinnedPageTests.until({ pane.stripModel.groups.count == 1 && pane.orderedIDs.map(\.rawValue) == ids })
            try await Self.select(ids[4], in: pane)
            pane.stripModel.send(.close(TabID(ids[4]), source: .mouse)) // b3, the group's last: b4 after the group, not b2
            try await Self.expect(pane, services, closed: [ids[4]], selects: ids[5], "the next tab outside the group")
            try await Self.select(ids[1], in: pane)
            try await connection.updateTabGroup(group, collapsed: true)
            try await PinnedPageTests.until({ pane.stripModel.groups.first?.isCollapsed == true })
            pane.stripModel.send(.close(TabID(ids[1]), source: .mouse)) // b0: the collapsed b1 b2 are skipped
            try await Self.expect(pane, services, closed: [ids[1]], selects: ids[5], "past a collapsed group")
        }
    }

    /// Close Tabs to the Right and Close Other Tabs are NOT changed by the one rule
    /// (close-selection-rule.md, "Close Others / Close to the Left / Right keep their rule"): Close
    /// Tabs to the Right closing the selected tab selects the tab the person acted on; Close Other
    /// Tabs keeps the selected tab it keeps.
    @Test func closeToTheRightAndCloseOthersKeepTheirRule() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let (pane, ids, _) = try await Self.pane(services, connection, browsers: 3) // T b0 b1 b2
            try await Self.select(ids[3], in: pane)
            pane.stripModel.send(.closeToRight(of: TabID(ids[1])))
            try await Self.expect(pane, services, closed: [ids[2], ids[3]], selects: ids[1], "Close Tabs to the Right")
            pane.stripModel.send(.closeOthers(keeping: TabID(ids[1])))
            try await Self.expect(pane, services, closed: [ids[0]], selects: ids[1], "Close Other Tabs")
        }
    }

    /// Rapid Cmd-W: each press closes the tab the close before it selected (the next tab,
    /// close-selection-rule.md R1 rank 4), with no stale index: from b0 of T b0 b1 b2 b3, three
    /// presses close b0, b1 and b2 and leave b3 selected.
    @Test func rapidCmdWClosesTheNextTabsInTurn() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let (pane, ids, _) = try await Self.pane(services, connection, browsers: 4)
            try await Self.select(ids[1], in: pane)
            for _ in 0..<3 { #expect(Self.cmdW(services)) }
            try await Self.expect(pane, services, closed: [ids[1], ids[2], ids[3]], selects: ids[4], "three quick Cmd-W")
            #expect(services.daemon.store.tab(id: ids[0]) != nil, "a quick Cmd-W closed the tab before the selection")
        }
    }
}
