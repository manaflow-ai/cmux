/// The credential-free input used to construct a phone-push request.
public struct PhonePushPayload: Sendable {
    /// The operation represented by the payload.
    public let kind: PhonePushPayloadKind
    /// The notification title.
    public let title: String
    /// The notification subtitle.
    public let subtitle: String
    /// The notification body.
    public let body: String
    /// The inline-reply affordance requested by the Mac notification.
    public let replyShape: String
    /// The workspace containing the notification source.
    public let workspaceId: String?
    /// The surface containing the notification source.
    public let surfaceId: String?
    /// Whether iOS may resolve the surface outside the explicit workspace.
    public let retargetsToLiveSurfaceOwner: Bool
    /// The stable Mac hardware identifier.
    public let macDeviceId: String?
    /// The app-build instance paired with ``macDeviceId``.
    public let macInstanceTag: String?
    /// The stable notification identifier.
    public let notificationId: String?
    /// The notification identifiers removed by a dismiss operation.
    public let notificationIds: [String]
    /// The authoritative unread total emitted as the APNs badge.
    public let badgeCount: Int
    /// Whether visible notification content must be redacted.
    public let hideContent: Bool

    /// Creates a fully specified push payload.
    public init(
        kind: PhonePushPayloadKind,
        title: String,
        subtitle: String,
        body: String,
        replyShape: String,
        workspaceId: String?,
        surfaceId: String?,
        retargetsToLiveSurfaceOwner: Bool,
        macDeviceId: String?,
        macInstanceTag: String?,
        notificationId: String?,
        notificationIds: [String],
        badgeCount: Int,
        hideContent: Bool
    ) {
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.replyShape = replyShape
        self.workspaceId = workspaceId
        self.surfaceId = surfaceId
        self.retargetsToLiveSurfaceOwner = retargetsToLiveSurfaceOwner
        self.macDeviceId = macDeviceId
        self.macInstanceTag = macInstanceTag
        self.notificationId = notificationId
        self.notificationIds = notificationIds
        self.badgeCount = badgeCount
        self.hideContent = hideContent
    }
}
