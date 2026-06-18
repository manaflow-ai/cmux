/// Stable terminal-notification identifiers owned by the app target and passed
/// into the delivery coordinator so the package does not duplicate app storage
/// constants.
public struct TerminalNotificationDeliveryIdentifiers: Sendable, Equatable {
    /// The `UNNotificationCategory` identifier used by terminal notifications.
    public let categoryIdentifier: String

    /// The explicit "show" action identifier used by terminal notifications.
    public let showActionIdentifier: String

    /// Creates terminal notification identifiers for category installation and
    /// response routing.
    public init(categoryIdentifier: String, showActionIdentifier: String) {
        self.categoryIdentifier = categoryIdentifier
        self.showActionIdentifier = showActionIdentifier
    }
}
