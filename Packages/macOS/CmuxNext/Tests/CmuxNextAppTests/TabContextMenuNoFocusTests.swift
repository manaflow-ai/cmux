import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
@testable import CmuxNextTabs
import Testing

/// manaflow-ai/cmux#24913: a 10 s main-thread hang on macOS 15.7.7 (fuzz seed 21, step 536): a
/// right-click on a tab built its menu (`PaneController.contextMenu`), which selected the tab through
/// the focus model; on a Chromium tab that focused the page, CEF made its window key
/// (`makeKeyAndOrderFront`), and the key change walked the window's views. Building a menu is not a
/// choice of tab: the menu acts on the tab it names, and the selection and focus stay where they were
/// (Chrome does not activate a right-clicked tab either).
@MainActor @Suite(.serialized, .timeLimit(.minutes(4)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct TabContextMenuNoFocusTests {
    @Test func aTabMenuSelectsNothingAndMovesNoFocus() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let pane = try #require(services.windows.active?.workspaceContent?.panes.values.first)
            for _ in pane.pane.tabs.count..<2 { _ = try await connection.newTab(in: pane.pane.handle) }
            try await PinnedPageTests.until({ pane.stripModel.tabs.count >= 2 }, report: { "\(pane.stripModel.tabs.map(\.id))" })
            let ids = pane.stripModel.orderedTabs.map(\.id)
            let selected = try #require(pane.stripModel.selectedID)
            let other = try #require(ids.first { $0 != selected })
            let focus = try #require(services.windows.active?.focus)
            let before = focus.state.resolved
            let menu = pane.contextMenu(for: .tab(other, selection: pane.stripModel.contextSelection(for: other)))
            #expect(menu != nil)
            #expect(pane.stripModel.selectedID == selected, "the menu selected \(other)")
            #expect(focus.state.resolved == before, "the menu moved focus: \(before) -> \(focus.state.resolved)")
        }
    }
}
