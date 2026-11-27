import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextSettings
import Foundation
import Testing

/// u2414 (2026-10-19): the unread ring must go away when the person goes into the pane. Clicks,
/// keys, opens and focus reach ``NotificationCenterService/interacted(_:tab:)``; with the default
/// settings (`focus`, as in cmux classic, https://github.com/manaflow-ai/cmux/issues/25662) each one
/// reads the tab at once. Under `click`, focus alone does not.
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
    func goingIntoTheTabReadsItWithTheDefaultSettings(_ trigger: NotificationTrigger) throws {
        let (service, tab) = try Self.unreadTab()
        service.interacted(trigger, tab: tab)
        #expect(service.log.contains("ack \(tab.id)"), "\(trigger) left the ring on")
    }

    /// Under `click`, chosen in Settings, focus alone keeps the ring until the pane is clicked or typed in.
    @Test func focusAloneKeepsTheRingUnderTheClickMode() throws {
        let (service, tab) = try Self.unreadTab()
        service.preferences.dismissal = .click
        service.interacted(.focus, tab: tab)
        #expect(!service.log.contains("ack \(tab.id)"), "focus cleared the ring")
    }

    /// Only going into the pane (a click, a key, an open) makes its ring blink out; a dismiss verb
    /// (Mark Read) or a timeout clears it without the flash.
    @Test(arguments: [NotificationTrigger.click, .keystroke, .open])
    func goingIntoThePaneMarksItForTheDismissFlash(_ trigger: NotificationTrigger) throws {
        let (service, tab) = try Self.unreadTab()
        service.interacted(trigger, tab: tab)
        #expect(service.entryReads.contains(tab.id))
    }

    @Test func markReadAndATimeoutClearWithoutTheFlash() throws {
        let (service, tab) = try Self.unreadTab()
        service.acknowledge(tab)
        #expect(!service.entryReads.contains(tab.id), "Mark Read would flash")
        let (timed, other) = try Self.unreadTab()
        timed.preferences.dismissal = .timeout
        timed.interacted(.timeout, tab: other)
        #expect(timed.log.contains("ack \(other.id)"))
        #expect(!timed.entryReads.contains(other.id), "a timeout would flash")
    }
}
