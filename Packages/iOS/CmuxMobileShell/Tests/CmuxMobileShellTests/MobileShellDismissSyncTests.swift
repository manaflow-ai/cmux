import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation
import Testing
import UserNotifications
@testable import CmuxMobileShell

@MainActor
@Suite struct MobileShellDismissSyncTests {
    private func makeStore(
        clearer: any DeliveredNotificationClearing,
        pendingDismissQueue: PendingNotificationDismissQueue =
            PendingNotificationDismissQueue(defaults: UserDefaults(suiteName: "dismiss-queue-\(UUID().uuidString)")!)
    ) -> MobileShellComposite {
        MobileShellComposite(
            workspaces: [],
            deliveredNotificationClearer: clearer,
            pendingDismissQueue: pendingDismissQueue,
            pairingHintDefaults: UserDefaults(suiteName: "dismiss-sync-\(UUID().uuidString)")!
        )
    }

    @Test func clearsDeliveredBannersForDismissedIDs() async {
        let clearer = RecordingDeliveredNotificationClearer()
        let store = makeStore(clearer: clearer)

        await store.clearDeliveredNotifications(ids: ["n-1", "n-2"])

        #expect(clearer.clearedIDs == [["n-1", "n-2"]])
    }

    @Test func trimsAndDropsBlankIDsBeforeClearing() async {
        let clearer = RecordingDeliveredNotificationClearer()
        let store = makeStore(clearer: clearer)

        await store.clearDeliveredNotifications(ids: ["  n-3  ", "", "   "])

        #expect(clearer.clearedIDs == [["n-3"]])
    }

    @Test func noOpsWhenNoUsableIDs() async {
        let clearer = RecordingDeliveredNotificationClearer()
        let store = makeStore(clearer: clearer)

        await store.clearDeliveredNotifications(ids: ["", "   "])

        #expect(clearer.clearedIDs.isEmpty)
    }

    @Test func dismissWithoutChannelParksIDsInDurableOutbox() async {
        let queue = PendingNotificationDismissQueue(
            defaults: UserDefaults(suiteName: "dismiss-queue-\(UUID().uuidString)")!
        )
        let store = makeStore(
            clearer: RecordingDeliveredNotificationClearer(),
            pendingDismissQueue: queue
        )

        await store.dismissNotification(ids: [" n-1 ", "", "n-2"])

        #expect(queue.pendingIDs == ["n-1", "n-2"])
    }

    @Test func dismissWithNoUsableIDsLeavesOutboxEmpty() async {
        let queue = PendingNotificationDismissQueue(
            defaults: UserDefaults(suiteName: "dismiss-queue-\(UUID().uuidString)")!
        )
        let store = makeStore(
            clearer: RecordingDeliveredNotificationClearer(),
            pendingDismissQueue: queue
        )

        await store.dismissNotification(ids: ["", "   "])

        #expect(queue.pendingIDs.isEmpty)
    }

    @Test func setsBadgeToAuthoritativeTotal() {
        let clearer = RecordingDeliveredNotificationClearer()
        let store = makeStore(clearer: clearer)

        store.applyAuthoritativeUnreadBadge(7)
        store.applyAuthoritativeUnreadBadge(0)

        #expect(clearer.badgeCounts == [7, 0])
    }

    @Test func clampsNegativeBadgeToZero() {
        let clearer = RecordingDeliveredNotificationClearer()
        let store = makeStore(clearer: clearer)

        store.applyAuthoritativeUnreadBadge(-3)

        #expect(clearer.badgeCounts == [0])
    }

    @Test func reconcileClearsHandledBannersAndSetsBadge() async throws {
        let clearer = RecordingDeliveredNotificationClearer()
        let store = makeStore(clearer: clearer)
        let response = try MobileNotificationReconcileResponse.decode(Data("""
        {"handled_ids": ["n-1", "n-3"], "unread_count": 2}
        """.utf8))

        await store.applyNotificationReconcile(response)

        #expect(clearer.clearedIDs == [["n-1", "n-3"]])
        #expect(clearer.badgeCounts == [2])
    }

    @Test func reconcileWithNothingHandledOnlySetsBadge() async throws {
        let clearer = RecordingDeliveredNotificationClearer()
        let store = makeStore(clearer: clearer)
        let response = try MobileNotificationReconcileResponse.decode(Data("""
        {"handled_ids": [], "unread_count": 0}
        """.utf8))

        await store.applyNotificationReconcile(response)

        #expect(clearer.clearedIDs.isEmpty)
        #expect(clearer.badgeCounts == [0])
    }

    @Test func reconcileFromOlderMacWithoutCountLeavesBadgeAlone() async throws {
        let clearer = RecordingDeliveredNotificationClearer()
        let store = makeStore(clearer: clearer)
        let response = try MobileNotificationReconcileResponse.decode(Data("""
        {"handled_ids": ["n-9"]}
        """.utf8))

        await store.applyNotificationReconcile(response)

        #expect(clearer.clearedIDs == [["n-9"]])
        #expect(clearer.badgeCounts.isEmpty)
    }

    @Test func macNotificationIDPrefersPayloadKeyOverRequestIdentifier() {
        let content = UNMutableNotificationContent()
        content.userInfo = ["cmux": ["notificationId": " mac-id-1 "]]
        let request = UNNotificationRequest(
            identifier: "os-assigned-identifier",
            content: content,
            trigger: nil
        )

        #expect(SystemDeliveredNotificationClearer.macNotificationID(for: request) == "mac-id-1")
    }

    @Test func macNotificationIDFallsBackToRequestIdentifier() {
        let content = UNMutableNotificationContent()
        let request = UNNotificationRequest(
            identifier: "legacy-collapse-id",
            content: content,
            trigger: nil
        )

        #expect(SystemDeliveredNotificationClearer.macNotificationID(for: request) == "legacy-collapse-id")
    }

    @Test func dismissedEventDecodesUnreadCount() {
        let event = MobileNotificationDismissedEvent.decode(Data("""
        {"ids": ["a", " b "], "unread_count": 4}
        """.utf8))

        #expect(event?.ids == ["a", "b"])
        #expect(event?.unreadCount == 4)
    }

    @Test func dismissedEventToleratesMissingUnreadCount() {
        let event = MobileNotificationDismissedEvent.decode(Data("""
        {"ids": ["a"]}
        """.utf8))

        #expect(event?.ids == ["a"])
        #expect(event?.unreadCount == nil)
    }

    @Test func badgeEventDecodesUnreadCount() {
        let event = MobileNotificationBadgeEvent.decode(Data("""
        {"unread_count": 12}
        """.utf8))

        #expect(event?.unreadCount == 12)
    }
}
