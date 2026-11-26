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

    @Test("Global cap keeps newest rows across many newest-first sources")
    func globalCapAcrossManySources() {
        let cap = MobileNotificationFeedAggregation.maxItemCount
        let olderSources = (0..<25).map { offset in
            [
                item(
                    mac: "old-\(offset)",
                    id: "old-\(offset)",
                    createdAt: Date(timeIntervalSince1970: Double(offset))
                )
            ]
        }
        let newerItems = (0..<cap).reversed().map { offset in
            item(
                mac: "new",
                id: "new-\(offset)",
                createdAt: Date(timeIntervalSince1970: 10_000 + Double(offset))
            )
        }

        let result = MobileNotificationFeedAggregation().items(from:
            (olderSources + [newerItems]).map { sourceItems in
                MobileNotificationFeedSourceSnapshot(items: sourceItems)
            }
        )

        #expect(result.count == cap)
        #expect(result.allSatisfy { $0.macDeviceID == "new" })
        #expect(result.first?.notificationID == "new-\(cap - 1)")
        #expect(result.last?.notificationID == "new-0")
    }

    @Test("Source status is projected only onto retained rows")
    func sourceStatusProjection() {
        let retained = item(
            mac: "mac",
            id: "retained",
            createdAt: Date(timeIntervalSince1970: 1),
            connectionStatus: .connected
        )

        let result = MobileNotificationFeedAggregation().items(from: [
            MobileNotificationFeedSourceSnapshot(
                items: [retained],
                connectionStatus: .reconnecting
            )
        ])

        #expect(result.first?.connectionStatus == .reconnecting)
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
        isRead: Bool = false,
        connectionStatus: MobileMacConnectionStatus = .connected
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
            connectionStatus: connectionStatus
        )
    }
}
