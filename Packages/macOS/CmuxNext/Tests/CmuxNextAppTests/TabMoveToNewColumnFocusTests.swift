import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextTabs
import Foundation
import Testing

/// Move Tab to New Column from the keyboard (lead 2026-10-24): the keys stay on the moved tab in its
/// new column in the input's turn, not one daemon reply later; the source pane keeps its other tab.
/// Runs the action against a same-tree cmux-tui that advertises `tab-column-client-keys-v1`.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct TabMoveToNewColumnFocusTests {
    @Test func theMovedTabHasTheFocusInItsNewColumnInTheInputsTurn() async throws {
        try await PinnedPageTests.withApp { services, connection in
            try #require(services.daemon.supports(DaemonCapability.tabColumnClientKeys.rawValue),
                         "the daemon does not advertise tab-column-client-keys-v1 (PL-daemon)")
            let store = services.daemon.store
            let content = try #require(services.windows.active?.workspaceContent)
            let model = try #require(store.workspaces.first?.screens.first?.panes.first)
            let source = try #require(services.paneController(for: model))
            let created = try await connection.newTab(in: model.handle)
            try await PinnedPageTests.until({ store.tab(surface: created.surface).map { source.orderedIDs.map(\.rawValue).contains($0.id) } == true })
            let moved = try #require(store.tab(surface: created.surface)?.id)
            source.select(TabID(moved))
            PaneHandlers.focus(source.layoutPaneID, in: content)
            try await PinnedPageTests.until({ content.focusedPane === source && source.stripModel.selectedID?.rawValue == moved })

            #expect(services.registry.perform("tab.moveToNewColumn", invocation: ActionInvocation(origin: .user)))

            // The same turn: no await between the action and these reads.
            let focused = content.focusedPane
            #expect(focused !== source, "the focus stayed in the source pane after the move")
            #expect(focused?.pane.tabs.contains { $0.id == moved } == true, "the focused pane does not hold the moved tab")
            #expect(source.pane.tabs.contains { $0.id == moved } == false, "the moved tab is still in its source pane")
        }
    }
}
