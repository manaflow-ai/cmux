import Foundation

/// Sendable payload copied at the synchronous Ghostty callback boundary. Remote byte
/// streams (the ssh-tmux mirror, cloud machine event streams) reuse it to enter the same
/// bounded ingress; they pass `hookDirectory: nil` (no local project hooks for a remote
/// emitter) and a non-local `origin`.
struct GhosttyDesktopNotificationRequest: Equatable, Sendable {
    let tabId: UUID
    let surfaceId: UUID?
    let hookDirectory: String?
    let title: String
    let body: String
    /// Host-owned text (a machine name); the terminal protocol carries no subtitle.
    let subtitle: String
    let origin: TerminalNotificationOrigin

    init(
        tabId: UUID,
        surfaceId: UUID?,
        hookDirectory: String?,
        title: String,
        body: String,
        subtitle: String = "",
        origin: TerminalNotificationOrigin = .local
    ) {
        self.tabId = tabId
        self.surfaceId = surfaceId
        self.hookDirectory = hookDirectory
        self.title = title
        self.body = body
        self.subtitle = subtitle
        self.origin = origin
    }
}
