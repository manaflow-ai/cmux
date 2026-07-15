import Foundation

/// Sendable payload copied at the synchronous Ghostty callback boundary.
/// A nil tab means the app-level callback targets the selected workspace.
nonisolated struct GhosttyDesktopNotificationRequest: Equatable, Sendable {
    let tabId: UUID?
    let surfaceId: UUID?
    let title: String
    let body: String
}
