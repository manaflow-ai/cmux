/// Byte limits applied while decoding notification-feed list payloads.
public struct MobileNotificationFeedListStringLimits: Sendable {
    /// Maximum UTF-8 bytes accepted for notification, workspace, and surface identifiers.
    public let identifierByteLimit: Int
    /// Maximum UTF-8 bytes retained for notification titles.
    public let titleByteLimit: Int
    /// Maximum UTF-8 bytes retained for notification subtitles.
    public let subtitleByteLimit: Int
    /// Maximum UTF-8 bytes retained for notification bodies.
    public let bodyByteLimit: Int
    /// Maximum UTF-8 bytes retained for display metadata.
    public let metadataByteLimit: Int

    /// Creates non-negative string limits for defensive feed decoding.
    public init(
        identifierByteLimit: Int,
        titleByteLimit: Int,
        subtitleByteLimit: Int,
        bodyByteLimit: Int,
        metadataByteLimit: Int
    ) {
        self.identifierByteLimit = max(0, identifierByteLimit)
        self.titleByteLimit = max(0, titleByteLimit)
        self.subtitleByteLimit = max(0, subtitleByteLimit)
        self.bodyByteLimit = max(0, bodyByteLimit)
        self.metadataByteLimit = max(0, metadataByteLimit)
    }
}
