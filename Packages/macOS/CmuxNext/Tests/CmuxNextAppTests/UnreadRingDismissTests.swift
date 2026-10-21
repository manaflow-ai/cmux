import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextSettings
import Foundation
import Testing

/// u2414 (2026-10-19): the unread ring must go away the way classic's did. Focus and clicks reach
/// ``NotificationCenterService/interacted(_:tab:)`` (the viewed-tab observation sends `focus` for
/// every path that settles focus; a mouse-down sends `click`); with the default settings each one
/// reads the tab at once.
@MainActor
struct UnreadRingDismissTests {
    static func unreadTab() throws -> (NotificationCenterService, TabModel) {
        _ = NSApplication.shared
        let store = DaemonStore()
        let marker = TabNotification(notification: NotificationID(rawValue: 4), unread: true, level: .info, source: "agent")
        let pane = PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1, terminalResourceID: "term_7", notification: marker)])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])]))
        let tab = try #require(store.workspaces.first?.screens.first?.panes.first?.tabs.first)
        #expect(tab.hasUnread, "the fixture's tab holds an unread notification")
        return (NotificationCenterService(), tab)
    }

    @Test(arguments: [NotificationTrigger.focus, .click, .keystroke, .open])
    func lookingAtTheTabReadsItWithTheDefaultSettings(_ trigger: NotificationTrigger) throws {
        let (service, tab) = try Self.unreadTab()
        service.interacted(trigger, tab: tab)
        #expect(service.log.contains("ack \(tab.id)"), "\(trigger) left the ring on")
    }
}
