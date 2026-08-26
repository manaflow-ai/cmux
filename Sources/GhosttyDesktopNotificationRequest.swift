import Foundation

/// Sendable payload copied at the synchronous Ghostty callback boundary.
struct GhosttyDesktopNotificationRequest: Equatable, Sendable {
    let tabId: UUID
    let surfaceId: UUID?
    let hookDirectory: String?
    let title: String
    let body: String
}
