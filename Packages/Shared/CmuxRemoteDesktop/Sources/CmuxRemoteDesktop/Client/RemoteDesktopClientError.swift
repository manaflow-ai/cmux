/// Why a remote desktop stream could not open or act.
public enum RemoteDesktopClientError: Error, Hashable, Sendable {
    /// `channel.refused` with the host's code (`rd.permission_denied`,
    /// `rd.display_not_found`, `rd.vnc_not_allowed`, `auth.revoked`, ...).
    case refused(code: String, message: String)
    /// The Mac's answer did not follow the `rd` binding.
    case protocolViolation(String)
    /// The session to the Mac is gone (reconnect and open again).
    case linkLost
    /// Not open (never opened, or closed).
    case notOpen
}
