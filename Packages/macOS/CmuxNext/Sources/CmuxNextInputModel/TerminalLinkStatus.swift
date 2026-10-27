/// Why a terminal view lost its daemon stream (shown in its placeholder).
public nonisolated enum TerminalDisconnectReason: Hashable, Sendable {
    /// The daemon ended the stream (`detached`).
    case streamEnded
    /// The attach connection closed.
    case connectionLost
    /// An attach did not complete.
    case attachFailed
    /// The view fell behind again and again (overflow limit).
    case fellBehind
}

/// What a terminal view shows about its daemon link.
public nonisolated enum TerminalLinkStatus: Hashable, Sendable {
    case connected
    /// A restored view has not shown its terminal yet: its first attach, or
    /// a retry after that attach failed (cx-wwtam).
    case restoring
    /// The last screen stays; `reconnecting` while one re-attach runs.
    case disconnected(TerminalDisconnectReason, reconnecting: Bool)
    /// The terminal's process ended; the view never re-attaches.
    case exited
}
