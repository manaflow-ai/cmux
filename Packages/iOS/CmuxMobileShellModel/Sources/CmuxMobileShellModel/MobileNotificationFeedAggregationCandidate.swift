struct MobileNotificationFeedAggregationCandidate: Sendable {
    var item: MobileNotificationFeedItem
    var sourceIndex: Int
    var itemIndex: Int
    var connectionStatus: MobileMacConnectionStatus?
}
