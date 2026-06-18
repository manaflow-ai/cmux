import Foundation

/// The result of attempting to attach (mirror) a remote host's tmux server in a
/// dedicated cmux window.
///
/// The remote-tmux mirror reaches the host over plain pipes with no controlling
/// tty, so it cannot service interactive SSH authentication itself. When a host
/// needs a password / host-key confirmation / MFA / FIDO touch, the attach can
/// neither succeed nor be retried in place — instead it reports
/// ``authRequired(sshArgv:)`` so the caller (the `cmux ssh-tmux` CLI, which runs in a
/// real terminal) can run that `ssh` invocation **inline in the user's tty** to
/// open the shared ControlMaster, then re-issue the attach (which now multiplexes
/// over the authenticated master and succeeds).
enum RemoteTmuxAttachOutcome: Sendable {
    /// The host's sessions were mirrored into the dedicated window with the given
    /// cmux window id.
    case mirrored(windowId: UUID)

    /// The host needs interactive authentication first. `sshArgv` is the full
    /// `ssh` argv (element 0 is the `ssh` binary) that, run under a controlling
    /// tty, authenticates and opens the shared ControlMaster — after which the
    /// attach should be retried.
    case authRequired(sshArgv: [String])
}
