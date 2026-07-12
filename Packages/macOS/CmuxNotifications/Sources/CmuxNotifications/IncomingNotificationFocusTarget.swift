public import Foundation

/// Identifies the cmux workspace and optional surface that produced an incoming notification.
public struct IncomingNotificationFocusTarget: Sendable, Equatable {
    /// The workspace that owns the notification.
    public let workspaceId: UUID
    /// The surface to focus when the notification is surface-scoped.
    public let surfaceId: UUID?
    /// The app-target panel to focus when it is more precise than ``surfaceId``.
    public let panelId: UUID?

    /// Creates a focus target for an incoming notification.
    ///
    /// - Parameters:
    ///   - workspaceId: The workspace that owns the notification.
    ///   - surfaceId: The optional surface that produced the notification.
    ///   - panelId: The optional app-target panel that produced the notification.
    public init(workspaceId: UUID, surfaceId: UUID?, panelId: UUID? = nil) {
        self.workspaceId = workspaceId
        self.surfaceId = surfaceId
        self.panelId = panelId
    }
}
