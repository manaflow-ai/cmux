import Foundation

/// Result of the shared remote-tmux mirror attach preflight before UI mutation.
enum RemoteTmuxMirrorAttachPreflight: Sendable {
    /// The host needs interactive authentication first.
    case authRequired(sshArgv: [String])

    /// A concurrent attach completed while preflight was awaiting SSH.
    case mirrored(windowId: UUID)

    /// SSH discovery succeeded and these sessions are ready to mirror.
    case sessions([RemoteTmuxSession])
}
