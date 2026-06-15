public import Foundation

/// The focused workspace/surface for the focused-mark flow. Mirrors the
/// app-target `FocusedNotificationTarget`; the marker only sees this value.
public struct FocusedNotificationTarget: Sendable, Equatable {
    public let tabId: UUID
    public let surfaceId: UUID?

    public init(tabId: UUID, surfaceId: UUID?) {
        self.tabId = tabId
        self.surfaceId = surfaceId
    }
}
