public import Foundation

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
    /// The opaque identifier of the sidebar group owning ``workspaceId``,
    /// or nil when the workspace is ungrouped or the group is unresolved.
    public let workspaceGroupId: String?
    /// The owning group's display name captured at send time. User content:
    /// senders drop it under content hiding, and the request encoder never
    /// emits it for hidden content or without ``workspaceGroupId``.
    public let workspaceGroupName: String?
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
        workspaceGroupId: String?,
        workspaceGroupName: String?,
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
        self.workspaceGroupId = workspaceGroupId
        self.workspaceGroupName = workspaceGroupName
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

extension PhonePushPayload {
    /// Derives the wire pair for the workspace group owning a notification.
    ///
    /// The group id is opaque routing data and ships whenever a group is
    /// known. The display name is user content, so it is dropped when
    /// content hiding is on, and it never ships without the id.
    public static func workspaceGroupFields(
        groupId: UUID?,
        groupName: String?,
        hideContent: Bool
    ) -> (workspaceGroupId: String?, workspaceGroupName: String?) {
        guard let groupId else { return (nil, nil) }
        return (groupId.uuidString, hideContent ? nil : groupName)
    }
}
