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
            // The split shows its pane before the daemon has it (split-client-keys-v1): a tab made
            // in it meanwhile names a handle the daemon does not know. The daemon's pane, first.
            try await PinnedPageTests.until({ Self.isDaemonPane(b) }, report: { Self.describe(controller) })
            let before = Set(b.orderedIDs.map(\.rawValue))
            #expect(services.registry.perform("newSurface", invocation: Self.at(b)))
            // The daemon's tab, not the stand-in `newSurface` shows until the daemon's takes its place.
            try await PinnedPageTests.until({ Self.daemonTab(in: b, beyond: before) != nil }, report: { Self.describe(controller) })
            let target = try #require(Self.daemonTab(in: b, beyond: before))
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
            @MainActor func shownB() -> PaneController? {
                guard controller.workspaceContent?.workspace.id == id else { return nil }
                return controller.workspaceContent?.paneController(key: pane)
            }
            try await PinnedPageTests.until({ shownB() != nil }, within: .seconds(10),
                                            report: { "the window does not show the tab's workspace\n" + Self.describe(controller) })
            try await PinnedPageTests.until({ shownB()?.stripModel.selectedID?.rawValue == target }, within: .seconds(10),
                                            report: { "the tab was not selected\n" + Self.describe(controller) })
            try await PinnedPageTests.until({ controller.focus.state.pane == pane }, within: .seconds(10),
                                            report: { "the tab's pane did not take the focus\n" + Self.describe(controller) + Self.describeFocus(controller) })
            #expect(controller.workspaceContent?.focusedPane?.paneKey == pane)
        }
    }

    /// The one tab `pane` lists beyond `known`, once it is the daemon's: `newSurface` shows a
    /// stand-in first (`pending_tab_…`, ctrl-backtick-instant) whose id goes when the daemon's
    /// tab takes its place, and the New Tab page lists the daemon's tab.
    private static func daemonTab(in pane: PaneController, beyond known: Set<String>) -> String? {
        let fresh = pane.orderedIDs.map(\.rawValue).filter { !known.contains($0) }
        guard fresh.count == 1, let tab = fresh.first, !ProvisionalTab.isProvisional(tab) else { return nil }
        return tab
    }

    /// `pane` is the daemon's, not a split's provisional one (``ProvisionalPane``: its handle and
    /// its tab's surface live at 1 << 62 and above until the daemon's pane takes its place).
    private static func isDaemonPane(_ pane: PaneController) -> Bool {
        pane.pane.handle.rawValue < 1 << 62 && !pane.pane.tabs.contains { ProvisionalTab.isProvisional(surface: $0.surface) }
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

    /// The focus machine's side: what it shows, remembers and last reduced.
    private static func describeFocus(_ controller: WindowController) -> String {
        let focus = controller.focus
        return "\nfocus topology=\(focus.state.topology.workspace ?? "-") panes=\(focus.state.topology.panes.map(\.id)) generation=\(focus.state.generation)"
            + " expectation=\(focus.state.expectation.map { String(describing: $0) } ?? "-")"
            + "\nremembered=\(focus.rememberedPanes())\nrecent:\n" + focus.recent.joined(separator: "\n")
    }

    private static func describe(_ controller: WindowController) -> String {
        let panes = controller.workspaceContent.map { Array($0.panes.values) } ?? []
        return "focused=\(controller.focus.state.pane ?? "-") workspace=\(controller.workspaceContent?.workspace.id ?? "-")\n"
            + panes.map { "\($0.paneKey) tabs=\($0.orderedIDs.map(\.rawValue)) selected=\($0.stripModel.selectedID?.rawValue ?? "-")" }
            .joined(separator: "\n")
    }
}
