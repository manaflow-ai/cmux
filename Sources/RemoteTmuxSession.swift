import Foundation

/// A tmux session discovered on a remote host.
///
/// Mirrors the fields cmux requests from `tmux list-sessions`. The `id` is
/// tmux's native session id (e.g. `$2`), which is stable for the lifetime of
/// the remote tmux server and is what cmux keys its sidebar workspace on.
struct RemoteTmuxSession: Sendable, Equatable, Codable, Identifiable {
    /// tmux's native session id, e.g. `$2`.
    let id: String

    /// The session name, e.g. `main`.
    let name: String

    /// Number of windows in the session.
    let windowCount: Int

    /// Whether any client is currently attached to the session.
    let attached: Bool

    /// Session creation time as a Unix timestamp, when reported by tmux.
    let createdUnix: Int?

    init(id: String, name: String, windowCount: Int, attached: Bool, createdUnix: Int?) {
        self.id = id
        self.name = name
        self.windowCount = windowCount
        self.attached = attached
        self.createdUnix = createdUnix
    }
}
