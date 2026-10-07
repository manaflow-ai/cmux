public import CmuxMobileWire

/// Why a control-plane call failed.
public enum ControlPlaneError: Error, Hashable, Sendable {
    /// No connected session; nothing queues while the owner is unreachable.
    case notConnected
    /// The server speaks no version in the client's range (`proto.version_unsupported`).
    case versionUnsupported(ErrorFrame)
    /// The server answered with an error frame (a read, or an op whose outcome is unknown).
    case remote(ErrorFrame)
    /// The socket closed for good (revoked install, version mismatch) or the client was stopped.
    case closed(ControlPlaneCloseError)
    case stopped
}
