/// Display target and reconnect command for the remote terminal that just
/// disconnected.
///
/// Set right before the workspace creates a replacement terminal panel so the
/// replacement terminal stays visibly disconnected (printing the disconnect
/// banner and, when a reconnect command is available, waiting on Enter to
/// reconnect) instead of falling through to a local login shell.
///
/// A pure value carrying only the two strings the replacement script needs; the
/// workspace owns the live `pendingRemoteDisconnectReplacement` slot and the
/// `remoteDisconnectPlaceholderPanelIds` set that track which panels are in this
/// placeholder state.
public struct PendingRemoteDisconnectReplacement: Sendable, Equatable {
    /// The remote display target (host/label) shown in the disconnect banner.
    public let target: String

    /// The original remote terminal startup command to re-run on reconnect, or
    /// `nil` when there is nothing to reconnect to (the banner then shows the
    /// reconnect-unavailable hint).
    public let reconnectCommand: String?

    /// Creates a pending remote-disconnect replacement descriptor.
    public init(target: String, reconnectCommand: String?) {
        self.target = target
        self.reconnectCommand = reconnectCommand
    }
}
