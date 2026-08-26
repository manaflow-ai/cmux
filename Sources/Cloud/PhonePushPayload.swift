import CmuxPhonePush

extension PhonePushPayload {
    /// Builds the phone banner payload from the stored notification identity.
    init(
        notification: TerminalNotification,
        macDeviceId: String,
        macInstanceTag: String,
        badgeCount: Int,
        hideContent: Bool
    ) {
        self.init(
            kind: .notify,
            title: notification.title,
            subtitle: notification.subtitle,
            body: notification.body,
            replyShape: notification.replyShape.rawValue,
            workspaceId: notification.tabId.uuidString,
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
