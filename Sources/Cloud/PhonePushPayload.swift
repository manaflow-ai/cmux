import CmuxPhonePush
import Foundation

extension PhonePushPayload {
    /// Builds the phone banner payload from the stored notification identity.
    /// `workspaceGroup` is the resolved sidebar group owning the notification's
    /// workspace, or nil when ungrouped; its name is dropped under content
    /// hiding because a group name is user content while the id is opaque.
    init(
        notification: TerminalNotification,
        macDeviceId: String,
        macInstanceTag: String,
        badgeCount: Int,
        hideContent: Bool,
        workspaceGroup: (id: UUID, name: String)?
    ) {
        let groupFields = Self.workspaceGroupFields(
            groupId: workspaceGroup?.id,
            groupName: workspaceGroup?.name,
            hideContent: hideContent
        )
        self.init(
            kind: .notify,
            title: notification.title,
            subtitle: notification.subtitle,
            body: notification.body,
            replyShape: notification.replyShape.rawValue,
            workspaceId: notification.tabId.uuidString,
            workspaceGroupId: groupFields.workspaceGroupId,
            workspaceGroupName: groupFields.workspaceGroupName,
            surfaceId: notification.surfaceId?.uuidString,
            retargetsToLiveSurfaceOwner: notification.retargetsToLiveSurfaceOwner,
            macDeviceId: macDeviceId,
            macInstanceTag: macInstanceTag,
            notificationId: notification.id.uuidString,
            notificationIds: [],
            badgeCount: badgeCount,
            hideContent: hideContent
        )
    }
}
