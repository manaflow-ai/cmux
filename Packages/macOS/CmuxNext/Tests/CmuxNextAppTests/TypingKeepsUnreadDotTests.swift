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
/// A key's read still shows at once (a key goes into the tab, as a click does), but a rollback holds
/// key reads off for 2 s, doubling to 30 s, until the daemon's record changes the dot: typing at any
/// speed against a refusing daemon blinks the dot a few times, not once per key.
@MainActor
struct TypingKeepsUnreadDotTests {
    static let keys = 20
    /// The time between keys, about the recording's typing speed.
    static let keyGap: Duration = .milliseconds(150)

    /// An unread tab whose key reads are timed by a clock the test moves (`advance`).
    static func unreadTab() throws -> (NotificationCenterService, TabModel, DaemonStore, (Duration) -> Void) {
        _ = NSApplication.shared
        let store = DaemonStore()
        store.apply(snapshot: tree(unread: true))
        let tab = try #require(store.workspaces.first?.screens.first?.panes.first?.tabs.first)
        #expect(tab.showsUnread, "the fixture's tab shows its unread dot")
        var now = ContinuousClock.now
        tab.keyReadClock = { now }
        return (NotificationCenterService(), tab, store, { now += $0 })
    }

    static func tree(unread: Bool, notification: UInt64 = 4) -> DaemonTree {
        let marker = TabNotification(notification: NotificationID(rawValue: notification), unread: unread, level: .info, source: "agent")
        let pane = PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1, terminalResourceID: "term_7", notification: marker)])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])])
    }

    /// Types `keys` keys into `tab`, `keyGap` apart, running `answer` after each as the daemon's
    /// answer to whatever the key sent, and counts the dot's changes and the acks the keys sent.
    static func type(_ service: NotificationCenterService, _ tab: TabModel, advance: (Duration) -> Void,
                     answer: () -> Void) -> (changes: Int, acks: Int) {
        var shown = tab.showsUnread
        var changes = 0
        let note = { if tab.showsUnread != shown { changes += 1; shown = tab.showsUnread } }
        for _ in 0..<keys {
            service.interacted(.keystroke, tab: tab)
            note()
            answer()
            note()
            advance(keyGap)
        }
        let acks = service.log.filter { $0 == "ack \(tab.id)" }.count
        print("TYPING-UNREAD-DOT keys=\(keys) changes=\(changes) acks=\(acks)")
        return (changes, acks)
    }

    /// The daemon refuses each ack (the recording: `ack-tab-notifications: not connected`; the
    /// owner's onFailure rolls the read back). Over 3 s of typing the dot blinks twice (at the first
    /// key and once the 2 s hold ends), not once per key, and stays under the rollback budget.
    @Test func aRefusedReadNeverBlinksTheDotPerKey() throws {
        let (service, tab, _, advance) = try Self.unreadTab()
        let run = Self.type(service, tab, advance: advance) { tab.dropExpectedNotificationRead() }
        #expect(run.changes <= 4, "the dot changed \(run.changes) times in \(Self.keys) keys")
        #expect(run.acks <= 2, "\(run.acks) acks in \(Self.keys) keys")
        #expect(tab.showsUnread)
        #expect(tab.rollbacks.warnings.isEmpty)
    }

    /// The daemon keeps the marker unread and its echo restates it (an item another owner holds
    /// keeps the ring): one ack, and the dot changes once.
    @Test func aKeptMarkerNeverBlinksTheDotPerKey() throws {
        let (service, tab, store, advance) = try Self.unreadTab()
        let run = Self.type(service, tab, advance: advance) { store.apply(snapshot: Self.tree(unread: true)) }
        #expect(run.changes <= 1, "the dot changed \(run.changes) times in \(Self.keys) keys")
        #expect(run.acks == 1, "\(run.acks) acks for one marker")
    }

    /// The daemon reads the marker: the dot goes once.
    @Test func anAcceptedReadClearsTheDotOnce() throws {
        let (service, tab, store, advance) = try Self.unreadTab()
        let run = Self.type(service, tab, advance: advance) { store.apply(snapshot: Self.tree(unread: false)) }
        #expect(run.changes == 1)
        #expect(!tab.showsUnread)
    }

    /// After refusals, the daemon comes back: once the hold ends the next key reads, and the dot goes.
    /// No connection state and no notification id is cached, so a reconnect or a daemon restart that
    /// numbers notifications from 1 again never leaves a notification keys cannot read.
    @Test func aKeyReadsAgainOnceTheDaemonIsBack() throws {
        let (service, tab, store, advance) = try Self.unreadTab()
        service.interacted(.keystroke, tab: tab)
        tab.dropExpectedNotificationRead()
        #expect(tab.showsUnread)
        service.interacted(.keystroke, tab: tab)
        #expect(tab.showsUnread, "a key inside the hold blinked the dot")
        advance(.seconds(2))
        service.interacted(.keystroke, tab: tab)
        #expect(!tab.showsUnread, "the key after the hold did not read")
        store.apply(snapshot: Self.tree(unread: false))
        #expect(!tab.showsUnread)
        // A restarted daemon's new notification reuses id 4: the next key reads it at once.
        store.apply(snapshot: Self.tree(unread: true))
        service.interacted(.keystroke, tab: tab)
        #expect(!tab.showsUnread, "a reused notification id stayed unread under typing")
    }

    /// A refused Mark as Unread clear holds key reads off the same way.
    @Test func aRefusedMarkClearHoldsKeyReadsOff() throws {
        let (_, tab, _, advance) = try Self.unreadTab()
        tab.applyState(SessionStateMirror.TabRecord(markedUnread: true), progress: nil)
        #expect(tab.markedUnread && tab.keyMayRead())
        tab.expectMarkedUnread(false)
        tab.dropExpectedMarkedUnread(false)
        #expect(tab.markedUnread)
        #expect(!tab.keyMayRead(), "a rolled-back clear let the next key clear the mark again")
        advance(.seconds(2))
        #expect(tab.keyMayRead(), "the hold never ended")
    }
}
