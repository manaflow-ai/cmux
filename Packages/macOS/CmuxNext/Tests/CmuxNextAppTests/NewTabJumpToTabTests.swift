import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextTabs
import Foundation
import Testing

/// Leo 2026-10-19: the New Tab page's "Switch to tab" row "doesn't jump to tab but to workspace".
/// A jump from a page in another workspace to an open tab shows the tab's workspace, selects that
/// exact tab and focuses its pane, as `tab.focus` does, even when the tab sits unselected in a
/// pane its workspace does not focus. It used to swap in the workspace only: the window's content
/// changes on a later turn, so the tab's pane was not there to select or focus yet. Runs the page's
/// jump against a same-tree cmux-tui daemon and the real window.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct NewTabJumpToTabTests {
    @Test func switchToTabSelectsAndFocusesThatTab() async throws {
        try await PinnedPageTests.withApp { services, _ in
            // Launch is over: its first workspace can no longer land over the test's.
            try await PinnedPageTests.until({ !services.windows.registry.isLaunching }, within: .seconds(60))
            let controller = try #require(services.windows.active)
            try #require(controller.window).setFrame(NSRect(x: 0, y: 0, width: 1100, height: 760), display: true)
            let id = try await services.windows.createWorkspace(WorkspaceSpawn(), into: controller.state.id)
            try await PinnedPageTests.until({ Self.shown(controller, workspace: id).count == 1 }, report: { Self.describe(controller) })
            let a = try #require(Self.shown(controller, workspace: id).first)

            // A | B, then a second tab in B: the target sits in B, unselected.
            #expect(services.registry.perform("splitRight", invocation: Self.at(a)))
            try await PinnedPageTests.until({ Self.shown(controller, workspace: id).count == 2 }, report: { Self.describe(controller) })
            let b = try #require(Self.shown(controller, workspace: id).first { $0 !== a })
            let before = Set(b.orderedIDs.map(\.rawValue))
            #expect(services.registry.perform("newSurface", invocation: Self.at(b)))
            try await PinnedPageTests.until({ b.orderedIDs.count == before.count + 1 }, report: { Self.describe(controller) })
            let target = try #require(b.orderedIDs.map(\.rawValue).first { !before.contains($0) })
            let other = try #require(before.first)
            b.select(CmuxNextTabs.TabID(other), source: .programmatic)
            controller.focus.send(.focusPane(a.paneKey, source: .intent))
            try await PinnedPageTests.until({ controller.focus.state.pane == a.paneKey && b.stripModel.selectedID?.rawValue == other },
                                            report: { Self.describe(controller) })

            // The New Tab page sits in another workspace; its row for that tab: Switch to tab.
            let page = try await services.windows.createWorkspace(WorkspaceSpawn(), into: controller.state.id)
            try await PinnedPageTests.until({ Self.shown(controller, workspace: page).count == 1 }, report: { Self.describe(controller) })
            NewTabPage.jump(.tab, id: target, services: services)

            // The window's content may be rebuilt: read the pane by its key.
            let pane = b.paneKey
            func shownB() -> PaneController? {
                guard controller.workspaceContent?.workspace.id == id else { return nil }
                return controller.workspaceContent?.paneController(key: pane)
            }
            try await PinnedPageTests.until({ shownB() != nil }, within: .seconds(10),
                                            report: { "the window does not show the tab's workspace\n" + Self.describe(controller) })
            try await PinnedPageTests.until({ shownB()?.stripModel.selectedID?.rawValue == target }, within: .seconds(10),
                                            report: { "the tab was not selected\n" + Self.describe(controller) })
            try await PinnedPageTests.until({ controller.focus.state.pane == pane }, within: .seconds(10),
                                            report: { "the tab's pane did not take the focus\n" + Self.describe(controller) })
            #expect(controller.workspaceContent?.focusedPane?.paneKey == pane)
        }
    }

    private static func at(_ pane: PaneController) -> ActionInvocation {
        ActionInvocation(target: ActionTargetRef(kind: .pane, id: pane.pane.id), origin: .cli)
    }

    /// The panes of `workspace`, shown in the window. A fresh session's Home can take the window
    /// back while the test waits, so each poll shows the workspace again.
    private static func shown(_ controller: WindowController, workspace: String) -> [PaneController] {
        if controller.workspaceContent?.workspace.id != workspace {
            controller.services.windows.show(workspaceID: workspace, in: controller.state)
        }
        guard let content = controller.workspaceContent, content.workspace.id == workspace else { return [] }
        return Array(content.panes.values)
    }

    private static func describe(_ controller: WindowController) -> String {
        let panes = controller.workspaceContent.map { Array($0.panes.values) } ?? []
        return "focused=\(controller.focus.state.pane ?? "-") workspace=\(controller.workspaceContent?.workspace.id ?? "-")\n"
            + panes.map { "\($0.paneKey) tabs=\($0.orderedIDs.map(\.rawValue)) selected=\($0.stripModel.selectedID?.rawValue ?? "-")" }
            .joined(separator: "\n")
    }
}
