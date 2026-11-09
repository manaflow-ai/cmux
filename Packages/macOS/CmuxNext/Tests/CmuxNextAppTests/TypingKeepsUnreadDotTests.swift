import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextSettings
import Foundation
import Testing

/// Leo, 2026-11-09: "when im typing in the composer the tab and workspace flicker... im typing while
/// not at the bottom of the screen". Each key in an agent chat's composer reached
/// ``NotificationCenterService/interacted(_:tab:owner:)`` as a `.keystroke`, which hid the tab's
/// unread dot at once (``TabModel/expectNotificationRead()``) and sent `ack-tab-notifications`. When
/// the daemon answered that the tab stays unread (a refused ack rolls the read back, or the marker
/// comes back), the dot came back one round trip later, and the next key hid it again: the tab's dot
/// and the workspace row's dot (both read ``TabModel/showsUnread``) blinked once per key, 88 and 40
/// times in the 15 s recording.
///
/// Keys read a marker once: the first key's read shows at once (a key goes into the tab, as a click
/// does), and a read the daemon refused or kept is never sent again by the next key, so the dot
/// changes at most twice for one marker, however many keys come.
@MainActor
struct TypingKeepsUnreadDotTests {
    static let keys = 20

    static func unreadTab() throws -> (NotificationCenterService, TabModel, DaemonStore) {
        _ = NSApplication.shared
        let store = DaemonStore()
        store.apply(snapshot: tree(unread: true))
        let tab = try #require(store.workspaces.first?.screens.first?.panes.first?.tabs.first)
        #expect(tab.showsUnread, "the fixture's tab shows its unread dot")
        return (NotificationCenterService(), tab, store)
    }

    static func tree(unread: Bool, notification: UInt64 = 4) -> DaemonTree {
        let marker = TabNotification(notification: NotificationID(rawValue: notification), unread: unread, level: .info, source: "agent")
        let pane = PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1, terminalResourceID: "term_7", notification: marker)])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])])
    }

    /// Types `keys` keys into `tab`, running `answer` after each as the daemon's answer to whatever
    /// the key sent, and counts the times the dot changed and the acks the keys sent.
    static func type(_ service: NotificationCenterService, _ tab: TabModel, answer: () -> Void) -> (changes: Int, acks: Int) {
        var shown = tab.showsUnread
        var changes = 0
        let note = { if tab.showsUnread != shown { changes += 1; shown = tab.showsUnread } }
        for _ in 0..<keys {
            service.interacted(.keystroke, tab: tab)
            note()
            answer()
            note()
        }
        let acks = service.log.filter { $0 == "ack \(tab.id)" }.count
        print("TYPING-UNREAD-DOT keys=\(keys) changes=\(changes) acks=\(acks)")
        return (changes, acks)
    }

    /// The daemon refuses each ack (the owner's onFailure rolls the read back): the first key's read
    /// shows and rolls back, and no later key sends (and blinks) it again.
    @Test func aRefusedReadNeverBlinksTheDotPerKey() throws {
        let (service, tab, _) = try Self.unreadTab()
        let run = Self.type(service, tab) { tab.dropExpectedNotificationRead() }
        #expect(run.changes <= 2, "the dot changed \(run.changes) times in \(Self.keys) keys")
        #expect(run.acks == 1, "\(run.acks) acks for one marker")
        #expect(tab.showsUnread)
        // Under the native indicator budget: it warns at more than 3 rollbacks of one tab in 2 s.
        #expect(tab.rollbacks.warnings.isEmpty)
    }

    /// The daemon keeps the marker unread and its echo restates it (an item another owner holds
    /// keeps the ring): the keys send one ack.
    @Test func aKeptMarkerNeverBlinksTheDotPerKey() throws {
        let (service, tab, store) = try Self.unreadTab()
        let run = Self.type(service, tab) { store.apply(snapshot: Self.tree(unread: true)) }
        #expect(run.changes <= 2, "the dot changed \(run.changes) times in \(Self.keys) keys")
        #expect(run.acks == 1, "\(run.acks) acks for one marker")
    }

    /// The daemon reads the marker: the dot goes once.
    @Test func anAcceptedReadClearsTheDotOnce() throws {
        let (service, tab, store) = try Self.unreadTab()
        let run = Self.type(service, tab) { store.apply(snapshot: Self.tree(unread: false)) }
        #expect(run.changes == 1)
        #expect(!tab.showsUnread)
    }

    /// A new notification on the tab is a new marker: the next key reads it (once).
    @Test func aNewMarkerIsReadByTheNextKey() throws {
        let (service, tab, store) = try Self.unreadTab()
        service.interacted(.keystroke, tab: tab)
        store.apply(snapshot: Self.tree(unread: true, notification: 5))
        service.interacted(.keystroke, tab: tab)
        service.interacted(.keystroke, tab: tab)
        #expect(service.log.filter { $0 == "ack \(tab.id)" }.count == 2)
    }
}
