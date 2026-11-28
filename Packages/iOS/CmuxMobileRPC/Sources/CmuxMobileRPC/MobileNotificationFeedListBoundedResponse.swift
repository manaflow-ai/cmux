struct MobileNotificationFeedListBoundedResponse: Decodable {
    let response: MobileNotificationFeedListResponse

    private enum CodingKeys: String, CodingKey {
        case revision
        case notifications
    }

    init(from decoder: any Decoder) throws {
        let options = try mobileNotificationFeedListBoundedDecodeOptions(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let revision = try container.decode(Int.self, forKey: .revision)
        var notificationsContainer = try container.nestedUnkeyedContainer(forKey: .notifications)
        var notifications: [MobileNotificationFeedListItem] = []
        notifications.reserveCapacity(min(options.maxNotifications, notificationsContainer.count ?? options.maxNotifications))
        while !notificationsContainer.isAtEnd, notifications.count < options.maxNotifications {
            try Task.checkCancellation()
            if let item = try notificationsContainer.decode(MobileNotificationFeedListBoundedItem.self).item {
                notifications.append(item)
            }
        }
        response = MobileNotificationFeedListResponse(
            revision: revision,
            notifications: notifications
        )
    }
}
