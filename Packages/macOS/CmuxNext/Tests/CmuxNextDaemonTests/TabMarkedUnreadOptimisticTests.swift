@testable import CmuxNextDaemon
import Testing

/// Mark Tab Read/Unread (Cmd-Opt-U) shows its dot in the same main-actor turn
/// as the key: the daemon's `tab.update` round trip (220-1000 ms on a busy
/// daemon) is never on the visible path. The record's echo confirms the mark;
/// a refused write rolls it back.
@MainActor
@Suite struct TabMarkedUnreadOptimisticTests {
    private func tab() -> TabModel { TabModel(TabSnapshot(surface: SurfaceID(rawValue: 7))) }

    @Test func aMarkShowsBeforeTheDaemonAnswers() {
        let tab = tab()
        tab.expectMarkedUnread(true)
        #expect(tab.markedUnread, "the dot shows with zero daemon round trips")
        #expect(tab.showsUnread)
    }

    @Test func anOlderRecordDoesNotUndoAPendingMark() {
        let tab = tab()
        tab.expectMarkedUnread(true)
        // A delta for another field (zoom) carries the old mark before the echo lands.
        tab.applyState(SessionStateMirror.TabRecord(zoom: 1.25, markedUnread: false), progress: nil)
        #expect(tab.markedUnread, "the pending mark wins over a record that predates it")
        tab.applyState(SessionStateMirror.TabRecord(zoom: 1.25, markedUnread: true), progress: nil)
        #expect(tab.markedUnread)
        // Settled: the daemon's record is the truth again (another client clears it).
        tab.applyState(SessionStateMirror.TabRecord(markedUnread: false), progress: nil)
        #expect(!tab.markedUnread, "after the echo the record decides")
    }

    @Test func aRefusedWriteRollsBack() {
        let tab = tab()
        tab.expectMarkedUnread(true)
        tab.dropExpectedMarkedUnread(true)
        #expect(!tab.markedUnread, "a refused write shows the record's value again")
    }

    @Test func aQuickSecondToggleKeepsTheLatestIntent() {
        let tab = tab()
        tab.expectMarkedUnread(true)
        tab.expectMarkedUnread(false)
        // The first write's echo arrives after the second toggle.
        tab.applyState(SessionStateMirror.TabRecord(markedUnread: true), progress: nil)
        #expect(!tab.markedUnread, "the newer toggle wins over the older echo")
        // The first write's failure must not undo the second toggle.
        tab.dropExpectedMarkedUnread(true)
        #expect(!tab.markedUnread)
        tab.applyState(SessionStateMirror.TabRecord(markedUnread: false), progress: nil)
        #expect(!tab.markedUnread)
    }

    private func notified(_ id: UInt64, unread: Bool = true) -> TabSnapshot {
        TabSnapshot(surface: SurfaceID(rawValue: 7), notification: TabNotification(notification: NotificationID(rawValue: id), unread: unread))
    }

    @Test func readingANotificationShowsBeforeTheAckAnswers() {
        let tab = TabModel(notified(1))
        #expect(tab.hasUnread)
        tab.expectNotificationRead()
        #expect(!tab.hasUnread, "read with zero daemon round trips")
        #expect(!tab.showsUnread)
        tab.update(TabSnapshot(surface: SurfaceID(rawValue: 7), title: "renamed",
                               notification: TabNotification(notification: NotificationID(rawValue: 1), unread: true)))
        #expect(!tab.hasUnread, "a tree change from before the ack keeps it read")
        tab.update(notified(1, unread: false))
        #expect(!tab.hasUnread)
        tab.update(notified(2))
        #expect(tab.hasUnread, "a newer notification shows unread")
    }

    @Test func aFailedAckShowsTheNotificationUnreadAgain() {
        let tab = TabModel(notified(1))
        tab.expectNotificationRead()
        tab.dropExpectedNotificationRead()
        #expect(tab.hasUnread)
    }
}
