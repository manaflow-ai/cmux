/// Immutable values grouped under one semantic notification-feed day.
public struct NotificationFeedDaySection<Item> {
    /// The semantic day shared by every item in this section.
    public let day: NotificationFeedDay
    /// Items in their incoming order.
    public let items: [Item]

    /// Creates a notification-feed day section.
    public init(day: NotificationFeedDay, items: [Item]) {
        self.day = day
        self.items = items
    }
}
