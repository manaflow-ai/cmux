import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import Testing

/// Blue ring (2026-10-20): the pane attention ring marks the tab the pane shows, as classic's ring
/// lived on the notifying terminal. A pane that shows a read tab (a Markdown file) while another
/// tab of it holds the unread notification draws no ring; that tab's unread dot marks it.
@MainActor
struct UnreadRingShownTabTests {
    /// One pane: a read tab first, then a tab with an unread notification; `activeTab` picks the shown one.
    static func workspace(activeTab: Int) throws -> WorkspaceModel {
        _ = NSApplication.shared
        let store = DaemonStore()
        let marker = TabNotification(notification: NotificationID(rawValue: 9), unread: true, level: .info, source: "agent")
        let pane = PaneSnapshot(id: 1, activeTab: activeTab, tabs: [
            TabSnapshot(surface: 1, terminalResourceID: "term_read"),
            TabSnapshot(surface: 2, terminalResourceID: "term_unread", notification: marker),
        ])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])]))
        return try #require(store.workspaces.first)
    }

    @Test func anUnreadTabBehindTheShownTabDrawsNoRing() throws {
        let workspace = try Self.workspace(activeTab: 0)
        let marks = NotificationCenterService().attentionMarks(for: workspace)
        #expect(marks.isEmpty, "the pane shows a read tab, yet the ring marks it: \(marks)")
    }

    @Test func theShownUnreadTabDrawsTheRing() throws {
        let workspace = try Self.workspace(activeTab: 1)
        #expect(NotificationCenterService().attentionMarks(for: workspace).count == 1)
    }
}
