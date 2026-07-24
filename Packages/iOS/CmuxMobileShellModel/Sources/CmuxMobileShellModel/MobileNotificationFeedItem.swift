public import Foundation

/// An immutable notification snapshot ready for presentation by the mobile shell.
public struct MobileNotificationFeedItem: Identifiable, Equatable, Sendable {
    /// The cross-Mac stable identity used by list diffing and action routing.
    public let id: MobileNotificationFeedItemID
    /// The stable device identifier of the Mac that emitted the notification.
    public let macDeviceID: String
    /// The notification identifier within the owning Mac.
    public let notificationID: String
    /// The owning Mac's user-facing name.
    public let macDisplayName: String
    /// The workspace identifier to send back to the owning Mac.
    public let remoteWorkspaceID: String
    /// The target pane or terminal-surface identifier to select, when present.
    public let remoteSurfaceID: String?
    /// The notification's primary title.
    public let title: String
    /// The notification's optional secondary title.
    public let subtitle: String?
    /// The notification body.
    public let body: String
    /// When the Mac created the notification.
    public let createdAt: Date
    /// Whether the notification has been read on the Mac.
    public let isRead: Bool
    /// Whether the target may follow its terminal to a different live workspace.
    public let retargetsToLiveSurfaceOwner: Bool
    /// The current destination workspace's display label, when available.
    public let workspaceTitle: String?
    /// The current destination pane's display label, when available.
    public let surfaceTitle: String?
    /// The current reachability of the owning Mac.
    public let connectionStatus: MobileMacConnectionStatus

    /// Creates an immutable notification-feed item.
    /// - Parameters:
    ///   - macDeviceID: The stable device identifier of the owning Mac.
    ///   - notificationID: The notification identifier within that Mac.
    ///   - macDisplayName: The owning Mac's user-facing name.
    ///   - remoteWorkspaceID: The Mac-local workspace identifier.
    ///   - remoteSurfaceID: The Mac-local target pane or terminal-surface identifier, when present.
    ///   - title: The notification's primary title.
    ///   - subtitle: The notification's optional secondary title.
    ///   - body: The notification body.
    ///   - createdAt: When the Mac created the notification.
    ///   - isRead: Whether the notification has been read on the Mac.
    ///   - retargetsToLiveSurfaceOwner: Whether a moved terminal may resolve in its live workspace.
    ///   - workspaceTitle: The current destination workspace label, when present.
    ///   - surfaceTitle: The current destination pane label, when present.
    ///   - connectionStatus: The current reachability of the owning Mac.
    public init(
        macDeviceID: String,
        notificationID: String,
        macDisplayName: String,
        remoteWorkspaceID: String,
        remoteSurfaceID: String? = nil,
        title: String,
        subtitle: String? = nil,
        body: String,
        createdAt: Date,
        isRead: Bool,
        retargetsToLiveSurfaceOwner: Bool = true,
        workspaceTitle: String? = nil,
        surfaceTitle: String? = nil,
        connectionStatus: MobileMacConnectionStatus
    ) {
        self.id = MobileNotificationFeedItemID(
            macDeviceID: macDeviceID,
            notificationID: notificationID
        )
        self.macDeviceID = macDeviceID
        self.notificationID = notificationID
        self.macDisplayName = macDisplayName
        self.remoteWorkspaceID = remoteWorkspaceID
        self.remoteSurfaceID = remoteSurfaceID
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.createdAt = createdAt
        self.isRead = isRead
        self.retargetsToLiveSurfaceOwner = retargetsToLiveSurfaceOwner
        self.workspaceTitle = workspaceTitle
        self.surfaceTitle = surfaceTitle
        self.connectionStatus = connectionStatus
    }

    /// Returns the same notification with updated read and connection state.
    /// - Parameters:
    ///   - isRead: The authoritative read state.
    ///   - connectionStatus: The current owning-Mac reachability.
    /// - Returns: A new immutable snapshot.
    public func updating(
        isRead: Bool? = nil,
        connectionStatus: MobileMacConnectionStatus? = nil
    ) -> MobileNotificationFeedItem {
        MobileNotificationFeedItem(
            macDeviceID: macDeviceID,
            notificationID: notificationID,
            macDisplayName: macDisplayName,
            remoteWorkspaceID: remoteWorkspaceID,
            remoteSurfaceID: remoteSurfaceID,
            title: title,
            subtitle: subtitle,
            body: body,
            createdAt: createdAt,
            isRead: isRead ?? self.isRead,
            retargetsToLiveSurfaceOwner: retargetsToLiveSurfaceOwner,
            workspaceTitle: workspaceTitle,
            surfaceTitle: surfaceTitle,
            connectionStatus: connectionStatus ?? self.connectionStatus
        )
    }
}
