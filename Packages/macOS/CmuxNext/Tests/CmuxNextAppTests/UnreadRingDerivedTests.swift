import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import Testing

/// The blue unread ring is derived (2026-10-21): a pane rings while the tab it shows reads unread
/// (`TabModel.showsUnread`: an unread notification or the Mark as Unread flag), the same value
/// the tab's dot, the screen bar and the sidebar row read. Mark as Unread on a tab brings the ring
/// back with no ring code of its own; reading the tab clears it.
@MainActor @Suite(.serialized)
struct UnreadRingDerivedTests {
    /// One pane with a read tab and a second tab; `notified` gives the second tab an unread
    /// notification. `activeTab` picks the shown one.
    static func workspace(activeTab: Int, notified: Bool = false) throws -> WorkspaceModel {
        _ = NSApplication.shared
        let store = DaemonStore()
        let marker = TabNotification(notification: NotificationID(rawValue: 7), unread: true, level: .info, source: "agent")
        let pane = PaneSnapshot(id: 1, activeTab: activeTab, tabs: [
            TabSnapshot(surface: 1, terminalResourceID: "term_first"),
            TabSnapshot(surface: 2, terminalResourceID: "term_second", notification: notified ? marker : nil),
        ])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])]))
        return try #require(store.workspaces.first)
    }

    static func tabs(_ workspace: WorkspaceModel) throws -> [TabModel] {
        try #require(workspace.screens.first?.panes.first?.tabs)
    }

    @Test func markAsUnreadOnTheShownTabDrawsTheRing() throws {
        let workspace = try Self.workspace(activeTab: 1)
        let tab = try Self.tabs(workspace)[1]
        let service = NotificationCenterService()
        #expect(service.attentionMarks(for: workspace).isEmpty)
        tab.expectMarkedUnread(true)
        let marks = service.attentionMarks(for: workspace)
        #expect(marks.count == 1, "Mark as Unread set the tab unread, yet its pane draws no ring")
        #expect(marks.values.first?.agentChat == false, "a marked terminal tab rings with the terminal look, not an agent chat's")
        #expect(service.hasHighlight(workspace), "Dismiss Highlight must show while the marked tab rings")
    }

    @Test func readingTheMarkedTabClearsTheRing() throws {
        let workspace = try Self.workspace(activeTab: 1)
        let tab = try Self.tabs(workspace)[1]
        let service = NotificationCenterService()
        tab.expectMarkedUnread(true)
        #expect(service.attentionMarks(for: workspace).count == 1)
        tab.expectMarkedUnread(false)
        #expect(service.attentionMarks(for: workspace).isEmpty, "the tab reads read, yet its pane still rings")
    }

    @Test func aMarkedTabBehindTheShownTabDrawsNoRing() throws {
        let workspace = try Self.workspace(activeTab: 0)
        try Self.tabs(workspace)[1].expectMarkedUnread(true)
        #expect(NotificationCenterService().attentionMarks(for: workspace).isEmpty)
    }

    /// The one rule: a pane rings exactly when its shown tab reads unread, the value every dot reads.
    @Test(arguments: [(false, false), (true, false), (false, true), (true, true)])
    func theRingFollowsTheTabsUnreadState(notified: Bool, marked: Bool) throws {
        let workspace = try Self.workspace(activeTab: 1, notified: notified)
        let tab = try Self.tabs(workspace)[1]
        if marked { tab.expectMarkedUnread(true) }
        let rings = !NotificationCenterService().attentionMarks(for: workspace).isEmpty
        #expect(rings == tab.showsUnread, "notified=\(notified) marked=\(marked): ring \(rings), tab unread \(tab.showsUnread)")
    }

    /// Dismiss Highlight hides a marked tab's ring like a notification's; marking it again
    /// (after it was read) rings again.
    @Test func dismissHidesAMarkedRingUntilTheTabIsMarkedAgain() throws {
        let workspace = try Self.workspace(activeTab: 1)
        let tab = try Self.tabs(workspace)[1]
        let service = NotificationCenterService()
        tab.expectMarkedUnread(true)
        service.dismissHighlight(workspace)
        #expect(service.attentionMarks(for: workspace).isEmpty, "Dismiss Highlight left the marked tab's ring")
        #expect(tab.showsUnread, "Dismiss Highlight read the tab; it must only hide the ring")
        tab.expectMarkedUnread(false)
        tab.expectMarkedUnread(true)
        #expect(service.attentionMarks(for: workspace).count == 1, "a new mark after a read must ring again")
    }
}
