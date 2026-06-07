import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

/// Records the ids passed to `removeDelivered` so a test can assert the Mac→iOS
/// dismiss-sync clears exactly the notifications the Mac dismissed, without
/// touching the real `UNUserNotificationCenter`. `@MainActor`-isolated because
/// the composite under test calls `removeDelivered` synchronously on the main
/// actor, so no lock is needed to keep the recorded state consistent.
@MainActor
private final class RecordingDeliveredNotificationClearer: DeliveredNotificationClearing {
    private(set) var clearedIDs: [[String]] = []

    nonisolated init() {}

    nonisolated func removeDelivered(ids: [String]) {
        MainActor.assumeIsolated {
            clearedIDs.append(ids)
        }
    }
}

/// Behavior tests for the phone-side half of cross-device notification
/// dismiss-sync: a Mac `notification.dismissed` event must clear the matching
/// delivered banners through the injected ``DeliveredNotificationClearing`` seam.
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
}
