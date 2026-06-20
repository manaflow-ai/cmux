/// The result of mirroring a remote host's tmux server in a dedicated cmux
/// window, for `remote.tmux.window`.
///
/// A Sendable transfer twin of the app-side `RemoteTmuxAttachOutcome`: the host
/// either mirrored (carrying the new/reused cmux window id as a string, matching
/// the legacy `windowId.uuidString`) or needs interactive authentication first
/// (carrying the full `ssh` argv the `cmux ssh-tmux` CLI runs in the user's
/// terminal). ``ControlRemoteTmuxWorker`` shapes each case onto the wire exactly
/// as the legacy `v2RemoteTmuxWindow` switch did.
public enum ControlRemoteTmuxAttachOutcome: Sendable, Equatable {
    /// The host's sessions were mirrored into the dedicated window; the value is
    /// the cmux window id rendered as `uuidString`.
    case mirrored(windowID: String)

    /// The host needs interactive authentication first; the value is the full
    /// `ssh` argv (element 0 is the `ssh` binary) to run under a controlling tty.
    case authRequired(sshArgv: [String])
}
