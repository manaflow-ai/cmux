import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// https://github.com/manaflow-ai/cmux/issues/44931: the sidebar workspace row's right-click menu had no Mark as
/// Read / Mark as Unread at its top level (Mark as Unread was under More, Mark as Read nowhere a person looked).
/// Classic offers both on the row's menu; NEXT shows the one that fits the row's unread dot, right after Pin.
/// The menu comes from the app's own registry and runs against a same-tree cmux-tui daemon: a click sets the
/// workspace's mark in the daemon, and the next menu offers the other row.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct WorkspaceMenuReadUnreadTests {
    private static let read: ActionID = "palette.markWorkspaceRead"
    private static let unread: ActionID = "palette.markWorkspaceUnread"

    /// The visible top-level rows of the workspace row's menu, each as the action it runs.
    private static func topRows(_ services: AppServices, _ workspace: WorkspaceModel) -> [(ActionID?, NSMenuItem)] {
        let menu = services.registry.makeContextMenu(for: .workspaceRow, target: ActionTargetRef(kind: .workspace, id: workspace.id))
        return menu.items.filter { !$0.isSeparatorItem && !$0.isHidden }.map { (ActionRegistry.menuRun(of: $0)?.id, $0) }
    }

    private static func click(_ item: NSMenuItem) throws {
        let action = try #require(item.action, "\(item.title) has no action")
        NSApp.sendAction(action, to: item.target, from: item)
    }

    @Test func theRowMenuOffersMarkAsUnreadThenMarkAsRead() async throws {
        try await PinnedPageTests.withApp { services, _ in
            let workspace = try #require(services.daemon.store.workspaces.first)
            #expect(!workspace.markedUnread && workspace.unreadCount == 0, "a fresh workspace has no unread dot")

            // A read row: Mark as Unread, after Pin, and no Mark as Read.
            var rows = Self.topRows(services, workspace)
            var ids = rows.map(\.0)
            let pin = try #require(ids.firstIndex(of: "palette.toggleWorkspacePin"), "\(ids)")
            #expect(ids.indices.contains(pin + 1) && ids[pin + 1] == Self.unread, "Mark as Unread follows Pin: \(ids)")
            #expect(!ids.contains(Self.read), "a read row offers no Mark as Read: \(ids)")
            try Self.click(try #require(rows.first { $0.0 == Self.unread }?.1))
            try await PinnedPageTests.until({ workspace.markedUnread }, report: { "the daemon never marked \(workspace.id) unread" })

            // An unread row: Mark as Read in the same place, and no Mark as Unread.
            rows = Self.topRows(services, workspace)
            ids = rows.map(\.0)
            let pinAgain = try #require(ids.firstIndex(of: "palette.toggleWorkspacePin"), "\(ids)")
            #expect(ids.indices.contains(pinAgain + 1) && ids[pinAgain + 1] == Self.read, "Mark as Read follows Pin: \(ids)")
            #expect(!ids.contains(Self.unread), "an unread row offers no Mark as Unread: \(ids)")

            try Self.click(try #require(rows.first { $0.0 == Self.read }?.1))
            try await PinnedPageTests.until({ !workspace.markedUnread }, report: { "the daemon never cleared \(workspace.id)'s mark" })
            #expect(Self.topRows(services, workspace).map(\.0).contains(Self.unread))
        }
    }

    /// The row's dot also shows for a tab marked unread by hand (the tab menu's Mark Tab as Unread), so the row
    /// offers Mark as Read; it drops the tab's mark, and the row offers Mark as Unread again.
    @Test func aTabMarkedUnreadMakesTheRowOfferMarkAsRead() async throws {
        try await PinnedPageTests.withApp { services, _ in
            let workspace = try #require(services.daemon.store.workspaces.first)
            let tab = try #require(workspace.screens.first?.panes.first?.tabs.first)
            try TabUnreadMark.set(true, tab: tab, daemon: services.daemon)
            try await PinnedPageTests.until({ tab.markedUnread }, report: { "the daemon never marked tab \(tab.id) unread" })
            #expect(!workspace.markedUnread, "only the tab is marked")

            let rows = Self.topRows(services, workspace)
            #expect(!rows.map(\.0).contains(Self.unread), "a row with a dot offers no Mark as Unread: \(rows.map(\.0))")
            try Self.click(try #require(rows.first { $0.0 == Self.read }?.1, "no Mark as Read: \(rows.map(\.0))"))
            try await PinnedPageTests.until({ !tab.markedUnread }, report: { "Mark as Read left tab \(tab.id)'s mark" })
            #expect(Self.topRows(services, workspace).map(\.0).contains(Self.unread))
        }
    }
}
