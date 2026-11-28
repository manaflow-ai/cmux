import Foundation
import Testing
@testable import CmuxNextDaemon

/// A notification's text reaches the sidebar only through its `notification` event: the tree
/// snapshot carries the tab's unread marker, not the text. The daemon follows each notification
/// with `tree-changed`, which resyncs, so a second notification that lands while that snapshot is
/// in flight sits under the snapshot's barrier. Dropping it as "covered by the snapshot" left the
/// row unread with no text (the hover card and Latest Notification row showed nothing).
@MainActor
struct StoreNotificationTextTests {
    private static func notification(_ id: UInt64, surface: UInt64, body: String) throws -> DaemonNotification {
        let json = #"{"notification":\#(id),"title":"","body":"\#(body)","level":"info","surface":\#(surface)}"#
        return try JSONDecoder().decode(DaemonNotification.self, from: Data(json.utf8))
    }

    /// A store whose tab on surface 1 has notification `id` unread, from a snapshot whose barrier
    /// is `barrier`, applied the way the driver's resync applies one.
    private static func storeAfterResync(unread id: UInt64, barrier: UInt64) -> DaemonStore {
        let store = DaemonStore()
        let marker = TabNotification(notification: NotificationID(rawValue: id), unread: true)
        let pane = PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1, notification: marker)])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])]))
        store.snapshotBarrier = max(store.snapshotBarrier, barrier)
        store.advanceAppliedSequence(to: barrier)
        return store
    }

    @Test func aNotificationHeldDuringAResyncKeepsItsText() throws {
        let store = Self.storeAfterResync(unread: 7, barrier: 12)
        let tab = try #require(store.tab(surface: 1))
        #expect(tab.hasUnread, "the snapshot brings the unread marker")
        // The held batch drains after the snapshot: the notification's sequence is under its barrier.
        _ = store.apply(batch: [DaemonEventEnvelope(sequence: 11, event: .notification(try Self.notification(7, surface: 1, body: "Tests pass")))])
        #expect(store.notificationText(for: tab) == "Tests pass")
        #expect(store.notifications.map(\.notification) == [NotificationID(rawValue: 7)], "the notification center hears it too")
    }

    @Test func aCollapsedInboxKeepsNotifications() throws {
        let inbox = EventInbox(limit: 2)
        _ = inbox.append(DaemonEventEnvelope(sequence: 1, event: .treeChanged(transaction: nil)))
        _ = inbox.append(DaemonEventEnvelope(sequence: 2, event: .notification(try Self.notification(3, surface: 1, body: "Deploy finished"))))
        _ = inbox.append(DaemonEventEnvelope(sequence: 3, event: .treeChanged(transaction: nil)))
        let kept = inbox.take().compactMap { if case .notification(let n) = $0.event { n.notification } else { nil } }
        #expect(kept == [NotificationID(rawValue: 3)], "the snapshot that answers the overflow has no notification text")
    }
}
