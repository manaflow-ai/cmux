/// Stable terminal-notification identifiers owned by the app target and passed
/// into the delivery coordinator so the package does not duplicate app storage
/// constants.
public struct TerminalNotificationDeliveryIdentifiers: Sendable, Equatable {
    /// The `UNNotificationCategory` identifier used by terminal notifications.
    public let categoryIdentifier: String

    /// The explicit "show" action identifier used by terminal notifications.
    public let showActionIdentifier: String

    /// The `userInfo` key carrying whether a notification may follow its live surface owner.
    public let retargetsToLiveSurfaceOwnerUserInfoKey: String

    /// Creates terminal notification identifiers for category installation and
    /// response routing.
    ///
    /// - Parameters:
    ///   - categoryIdentifier: Category identifier for terminal notifications.
    ///   - showActionIdentifier: Explicit show-action identifier.
    ///   - retargetsToLiveSurfaceOwnerUserInfoKey: `userInfo` key for routing provenance.
    public init(
        categoryIdentifier: String,
        showActionIdentifier: String,
        retargetsToLiveSurfaceOwnerUserInfoKey: String
    ) {
        self.categoryIdentifier = categoryIdentifier
        self.showActionIdentifier = showActionIdentifier
        self.retargetsToLiveSurfaceOwnerUserInfoKey = retargetsToLiveSurfaceOwnerUserInfoKey
    }
}
