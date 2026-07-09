/// One tmux session discovered on a remote host, shaped for the
/// `remote.tmux.sessions` reply.
///
/// A Sendable transfer twin of the app-side `RemoteTmuxSession`; the app
/// conformer maps each discovered session into this value, and
/// ``ControlRemoteTmuxWorker`` serializes it onto the wire (the legacy
/// `TerminalController.sessionPayload(_:)` shaping: `id`, `name`, `windows`,
/// `attached`, and `created` only when present).
public struct ControlRemoteTmuxSession: Sendable, Equatable {
    /// tmux's native session id, e.g. `$2`.
    public let id: String

    /// The session name, e.g. `main`.
    public let name: String

    /// Number of windows in the session (the wire `windows` field).
    public let windowCount: Int

    /// Whether any client is currently attached.
    public let attached: Bool

    /// Session creation time as a Unix timestamp, when reported by tmux;
    /// omitted from the wire payload when `nil`.
    public let createdUnix: Int?

    /// Creates a remote-tmux session value.
    ///
    /// - Parameters:
    ///   - id: tmux's native session id.
    ///   - name: The session name.
    ///   - windowCount: Number of windows.
    ///   - attached: Whether a client is attached.
    ///   - createdUnix: Optional creation Unix timestamp.
    public init(id: String, name: String, windowCount: Int, attached: Bool, createdUnix: Int?) {
        self.id = id
        self.name = name
        self.windowCount = windowCount
        self.attached = attached
        self.createdUnix = createdUnix
    }
}
