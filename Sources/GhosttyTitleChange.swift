import Foundation

/// Typed payload for `.ghosttyDidSetTitle` notifications.
struct GhosttyTitleChange: Equatable, Sendable {
    let tabId: UUID
    let surfaceId: UUID
    let title: String
    let sourceSurfaceIdentifier: ObjectIdentifier?
    let terminalLifecycleID: UUID?

    init(
        tabId: UUID,
        surfaceId: UUID,
        title: String,
        sourceSurfaceIdentifier: ObjectIdentifier? = nil,
        terminalLifecycleID: UUID? = nil
    ) {
        self.tabId = tabId
        self.surfaceId = surfaceId
        self.title = title
        self.sourceSurfaceIdentifier = sourceSurfaceIdentifier
        self.terminalLifecycleID = terminalLifecycleID
    }

    init?(notification: Notification) {
        guard let tabId = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID,
              let surfaceId = notification.userInfo?[GhosttyNotificationKey.surfaceId] as? UUID,
              let title = notification.userInfo?[GhosttyNotificationKey.title] as? String else {
            return nil
        }
        self.init(
            tabId: tabId,
            surfaceId: surfaceId,
            title: title,
            sourceSurfaceIdentifier: notification.userInfo?[GhosttyNotificationKey.sourceSurfaceIdentifier]
                as? ObjectIdentifier ?? (notification.object as AnyObject?).map(ObjectIdentifier.init),
            terminalLifecycleID: notification.userInfo?[GhosttyNotificationKey.terminalLifecycleID]
                as? UUID
        )
    }

    var userInfo: [String: Any] {
        var info: [String: Any] = [
            GhosttyNotificationKey.tabId: tabId,
            GhosttyNotificationKey.surfaceId: surfaceId,
            GhosttyNotificationKey.title: title,
        ]
        if let sourceSurfaceIdentifier {
            info[GhosttyNotificationKey.sourceSurfaceIdentifier] = sourceSurfaceIdentifier
        }
        if let terminalLifecycleID {
            info[GhosttyNotificationKey.terminalLifecycleID] = terminalLifecycleID
        }
        return info
    }

    /// Accepts only events from the expected surface and, when supplied, its
    /// current child-process generation. Ghostty ingress always supplies both;
    /// the optional generation preserves object-authenticated test and legacy
    /// in-process notifications.
    func matches(
        sourceSurface: AnyObject,
        terminalLifecycleID currentTerminalLifecycleID: UUID
    ) -> Bool {
        guard let sourceSurfaceIdentifier else { return false }
        guard sourceSurfaceIdentifier == ObjectIdentifier(sourceSurface) else {
            return false
        }
        guard let terminalLifecycleID else { return true }
        return terminalLifecycleID == currentTerminalLifecycleID
    }
}
