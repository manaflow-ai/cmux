public import Foundation

/// The focused workspace/surface for the focused-mark flow. Mirrors the
/// app-target `FocusedNotificationTarget`; the marker only sees this value.
public struct FocusedNotificationTarget: Sendable, Equatable {
    /// The id of the focused workspace (tab).
    public let tabId: UUID
    /// The id of the focused surface within the workspace, if any.
    public let surfaceId: UUID?

    /// Creates a focused-target value.
    public init(tabId: UUID, surfaceId: UUID?) {
        self.tabId = tabId
        self.surfaceId = surfaceId
    }
}
