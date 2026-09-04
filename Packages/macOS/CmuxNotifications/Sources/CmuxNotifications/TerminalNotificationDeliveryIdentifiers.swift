/// Stable terminal-notification identifiers owned by the app target and passed
/// into the delivery coordinator so the package does not duplicate app storage
/// constants.
public struct TerminalNotificationDeliveryIdentifiers: Sendable, Equatable {
    /// The `UNNotificationCategory` identifier used by terminal notifications.
    public let categoryIdentifier: String

    /// The `UNNotificationCategory` identifier used by text-reply notifications.
    public let textReplyCategoryIdentifier: String

    /// The explicit "show" action identifier used by terminal notifications.
    public let showActionIdentifier: String

    /// The text-input reply action identifier.
    public let replyActionIdentifier: String

    /// The `userInfo` key carrying whether a notification may follow its live surface owner.
    public let retargetsToLiveSurfaceOwnerUserInfoKey: String

    /// The `userInfo` key carrying the window that owned the notification when
    /// it was delivered. OS banner clicks use this provenance to avoid
    /// retargeting into a different window after a surface moves.
    public let windowIdUserInfoKey: String

    /// Creates terminal notification identifiers for category installation and
    /// response routing.
    ///
    /// - Parameters:
    ///   - categoryIdentifier: Category identifier for terminal notifications.
    ///   - textReplyCategoryIdentifier: Category identifier for text-reply notifications.
    ///   - showActionIdentifier: Explicit show-action identifier.
    ///   - replyActionIdentifier: Text-input reply action identifier.
    ///   - retargetsToLiveSurfaceOwnerUserInfoKey: `userInfo` key for routing provenance.
    ///   - windowIdUserInfoKey: `userInfo` key for the originating window id.
    public init(
        categoryIdentifier: String,
        textReplyCategoryIdentifier: String,
        showActionIdentifier: String,
        replyActionIdentifier: String,
        retargetsToLiveSurfaceOwnerUserInfoKey: String,
        windowIdUserInfoKey: String = "CMUX_NOTIFICATION_WINDOW_ID"
    ) {
        self.categoryIdentifier = categoryIdentifier
        self.textReplyCategoryIdentifier = textReplyCategoryIdentifier
        self.showActionIdentifier = showActionIdentifier
        self.replyActionIdentifier = replyActionIdentifier
        self.retargetsToLiveSurfaceOwnerUserInfoKey = retargetsToLiveSurfaceOwnerUserInfoKey
        self.windowIdUserInfoKey = windowIdUserInfoKey
    }
}
