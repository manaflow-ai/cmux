import Foundation
import Testing
@testable import CMUXMobileCore

/// Pins the mobile notification-sync wire parsing and dismiss decision: id
/// trimming, the 256-element scan cap, order-preserving dedupe (dismiss) vs
/// pass-through (reconcile), and the unread→read transition count.
@Suite struct MobileNotificationSyncRequestTests {
    private let a = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    private let b = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!
    private let c = UUID(uuidString: "00000000-0000-0000-0000-0000000000C3")!

    @Test func dismissParsesSingleAndArrayWithTrimAndDedupe() {
        let request = MobileNotificationSyncRequest(
            dismissSingleID: "  \(a.uuidString)  ",
            arrayIDs: [b.uuidString, a.uuidString, "  \(c.uuidString)", "", "not-a-uuid", nil]
        )
        // single first, then array order; the repeated `a` is deduped to its
        // first-seen position; empty/garbage/nil dropped.
        #expect(request.ids == [a, b, c])
    }

    @Test func dismissEmptyWhenNoValidIDs() {
        #expect(MobileNotificationSyncRequest(dismissSingleID: nil, arrayIDs: nil).ids.isEmpty)
        #expect(MobileNotificationSyncRequest(dismissSingleID: "   ", arrayIDs: ["", "x", nil]).ids.isEmpty)
    }

    @Test func dismissCapsArrayScanAt256() {
        // 256 junk elements push a valid id at index 256 past the cap.
        var arrayIDs: [String?] = Array(repeating: "not-a-uuid", count: MobileNotificationSyncRequest.maximumIDCount)
        arrayIDs.append(a.uuidString)
        #expect(MobileNotificationSyncRequest(dismissSingleID: nil, arrayIDs: arrayIDs).ids.isEmpty)
        // The single id is parsed independently of the array cap.
        #expect(
            MobileNotificationSyncRequest(dismissSingleID: a.uuidString, arrayIDs: arrayIDs).ids == [a]
        )
    }

    @Test func dismissPlanCountsOnlyUnreadTransitions() {
        let request = MobileNotificationSyncRequest(
            dismissSingleID: nil,
            arrayIDs: [a.uuidString, b.uuidString, c.uuidString]
        )
        // b is already read / c is unknown: only a transitions, in request order.
        #expect(request.dismissPlan(unreadIDs: [a]) == [a])
        #expect(request.dismissPlan(unreadIDs: [a, c]) == [a, c])
        #expect(request.dismissPlan(unreadIDs: []).isEmpty)
    }

    @Test func reconcileParsesDeliveredWithoutDedupe() {
        // reconcile passes ids straight through (no dedupe), trimming + dropping junk.
        let request = MobileNotificationSyncRequest(
            deliveredArrayIDs: ["  \(a.uuidString) ", a.uuidString, "", nil, b.uuidString, "nope"]
        )
        #expect(request.ids == [a, a, b])
    }

    @Test func reconcileEmptyIsValidBadgeOnlySync() {
        #expect(MobileNotificationSyncRequest(deliveredArrayIDs: nil).ids.isEmpty)
        #expect(MobileNotificationSyncRequest(deliveredArrayIDs: []).ids.isEmpty)
    }

    @Test func reconcileCapsScanAt256() {
        var arrayIDs: [String?] = Array(repeating: "not-a-uuid", count: MobileNotificationSyncRequest.maximumIDCount)
        arrayIDs.append(a.uuidString)
        #expect(MobileNotificationSyncRequest(deliveredArrayIDs: arrayIDs).ids.isEmpty)
    }
}
