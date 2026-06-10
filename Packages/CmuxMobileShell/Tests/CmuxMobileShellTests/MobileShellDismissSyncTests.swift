import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

/// Records the ids passed to `removeDelivered` and the counts passed to
/// `setBadgeCount` so a test can assert the Mac->iOS dismiss-sync clears exactly
/// the notifications the Mac dismissed and sets exactly the badge totals the Mac
/// computed, without touching the real `UNUserNotificationCenter`.
/// `@MainActor`-isolated because the composite under test calls the seam
/// synchronously on the main actor, so no lock is needed to keep the recorded
/// state consistent.
@MainActor
private final class RecordingDeliveredNotificationClearer: DeliveredNotificationClearing {
    private(set) var clearedIDs: [[String]] = []
    private(set) var badgeCounts: [Int] = []
    var deliveredIDs: [String] = []

    nonisolated init() {}

    nonisolated func removeDelivered(ids: [String]) {
        MainActor.assumeIsolated {
            clearedIDs.append(ids)
        }
    }

    nonisolated func deliveredIdentifiers() async -> [String] {
        await MainActor.run { deliveredIDs }
    }

    nonisolated func setBadgeCount(_ count: Int) {
        MainActor.assumeIsolated {
            badgeCounts.append(count)
        }
    }
}

/// Behavior tests for the phone-side half of cross-device notification
/// dismiss-sync: a Mac `notification.dismissed` event must clear the matching
/// delivered banners, badge events/reconcile results must SET the app-icon
/// badge to the Mac's authoritative total, all through the injected
/// ``DeliveredNotificationClearing`` seam.
@MainActor
@Suite struct MobileShellDismissSyncTests {
    private func makeStore(
        clearer: any DeliveredNotificationClearing
    ) -> MobileShellComposite {
        MobileShellComposite(
            workspaces: [],
            deliveredNotificationClearer: clearer,
            pairingHintDefaults: UserDefaults(suiteName: "dismiss-sync-\(UUID().uuidString)")!
        )
    }

    @Test func clearsDeliveredBannersForDismissedIDs() {
        let clearer = RecordingDeliveredNotificationClearer()
        let store = makeStore(clearer: clearer)

        store.clearDeliveredNotifications(ids: ["n-1", "n-2"])

        #expect(clearer.clearedIDs == [["n-1", "n-2"]])
    }

    @Test func trimsAndDropsBlankIDsBeforeClearing() {
        let clearer = RecordingDeliveredNotificationClearer()
        let store = makeStore(clearer: clearer)

        store.clearDeliveredNotifications(ids: ["  n-3  ", "", "   "])

        #expect(clearer.clearedIDs == [["n-3"]])
    }

    @Test func noOpsWhenNoUsableIDs() {
        let clearer = RecordingDeliveredNotificationClearer()
        let store = makeStore(clearer: clearer)

        store.clearDeliveredNotifications(ids: ["", "   "])

        #expect(clearer.clearedIDs.isEmpty)
    }

    // MARK: - Badge

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

    // MARK: - Reconcile sweep

    @Test func reconcileClearsHandledBannersAndSetsBadge() throws {
        let clearer = RecordingDeliveredNotificationClearer()
        let store = makeStore(clearer: clearer)
        let response = try MobileNotificationReconcileResponse.decode(Data("""
        {"handled_ids": ["n-1", "n-3"], "unread_count": 2}
        """.utf8))

        store.applyNotificationReconcile(response)

        #expect(clearer.clearedIDs == [["n-1", "n-3"]])
        #expect(clearer.badgeCounts == [2])
    }

    @Test func reconcileWithNothingHandledOnlySetsBadge() throws {
        let clearer = RecordingDeliveredNotificationClearer()
        let store = makeStore(clearer: clearer)
        let response = try MobileNotificationReconcileResponse.decode(Data("""
        {"handled_ids": [], "unread_count": 0}
        """.utf8))

        store.applyNotificationReconcile(response)

        #expect(clearer.clearedIDs.isEmpty)
        #expect(clearer.badgeCounts == [0])
    }

    @Test func reconcileFromOlderMacWithoutCountLeavesBadgeAlone() throws {
        let clearer = RecordingDeliveredNotificationClearer()
        let store = makeStore(clearer: clearer)
        let response = try MobileNotificationReconcileResponse.decode(Data("""
        {"handled_ids": ["n-9"]}
        """.utf8))

        store.applyNotificationReconcile(response)

        #expect(clearer.clearedIDs == [["n-9"]])
        #expect(clearer.badgeCounts.isEmpty)
    }

    // MARK: - Event payload decoding

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
