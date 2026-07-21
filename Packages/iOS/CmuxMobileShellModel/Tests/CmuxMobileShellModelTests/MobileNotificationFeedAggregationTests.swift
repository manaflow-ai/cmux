import CmuxMobileShellModel
import Foundation
import Testing

@Suite("Notification feed aggregation")
struct MobileNotificationFeedAggregationTests {
    @Test("Cross-Mac identity prevents local id collisions and sorting is stable")
    func crossMacIdentityAndStableSort() {
        let timestamp = Date(timeIntervalSince1970: 100)
        let macB = item(mac: "mac-b", id: "same", createdAt: timestamp)
        let macA = item(mac: "mac-a", id: "same", createdAt: timestamp)
        let newest = item(mac: "mac-a", id: "newest", createdAt: timestamp.addingTimeInterval(1))

        let result = MobileNotificationFeedAggregation().items(from: [[macB], [macA, newest]])

        #expect(result.map(\.id) == [newest.id, macA.id, macB.id])
        #expect(Set(result.map(\.id)).count == 3)
    }

    @Test("Unread filter preserves chronological input order")
    func unreadFilter() {
        let unread = item(mac: "mac", id: "unread", createdAt: Date(), isRead: false)
        let read = item(mac: "mac", id: "read", createdAt: Date(), isRead: true)

        #expect(MobileNotificationFeedFilter.unread.apply(to: [unread, read]) == [unread])
        #expect(MobileNotificationFeedFilter.all.apply(to: [unread, read]) == [unread, read])
    }

    private func item(
        mac: String,
        id: String,
        createdAt: Date,
        isRead: Bool = false
    ) -> MobileNotificationFeedItem {
        MobileNotificationFeedItem(
            macDeviceID: mac,
            notificationID: id,
            macDisplayName: mac,
            remoteWorkspaceID: "workspace",
            title: "Title",
            body: "Body",
            createdAt: createdAt,
            isRead: isRead,
            connectionStatus: .connected
        )
    }
}
