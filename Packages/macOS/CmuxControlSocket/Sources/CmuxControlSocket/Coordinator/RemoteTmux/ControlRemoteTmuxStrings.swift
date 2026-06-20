/// The localized `remote.tmux.*` error messages, resolved against the app
/// bundle so ``ControlRemoteTmuxWorker`` can shape the localized error envelopes
/// without binding `String(localized:)` to the package bundle (which lacks the
/// keys, silently dropping non-English translations = a wire change).
///
/// Each field carries the exact `String(localized:)` result the legacy
/// `v2RemoteTmux*` bodies produced.
public struct ControlRemoteTmuxStrings: Sendable, Equatable {
    /// `socket.remoteTmux.disabled` — the beta-flag-off error shared by every
    /// `remote.tmux.*` command.
    public let disabled: String

    /// `socket.remoteTmux.hostRequired` — the missing-host error for
    /// `remote.tmux.sessions`, `remote.tmux.attach`, `remote.tmux.mirror`, and
    /// `remote.tmux.window`.
    public let hostRequired: String

    /// `socket.remoteTmux.sessionRequired` — the missing-session error for
    /// `remote.tmux.attach`.
    public let sessionRequired: String

    /// `socket.remoteTmux.hostAndSessionRequired` — the missing-host-or-session
    /// error for `remote.tmux.detach` and `remote.tmux.state`.
    public let hostAndSessionRequired: String

    /// Creates the localized remote-tmux strings.
    ///
    /// - Parameters:
    ///   - disabled: The beta-flag-off error message.
    ///   - hostRequired: The missing-host error message.
    ///   - sessionRequired: The missing-session error message.
    ///   - hostAndSessionRequired: The missing-host-or-session error message.
    public init(
        disabled: String,
        hostRequired: String,
        sessionRequired: String,
        hostAndSessionRequired: String
    ) {
        self.disabled = disabled
        self.hostRequired = hostRequired
        self.sessionRequired = sessionRequired
        self.hostAndSessionRequired = hostAndSessionRequired
    }
}
