
public extension SocketControlMode {
    /// The POSIX permission bits to apply to the socket file for this mode.
    ///
    /// Every mode keeps the socket private to the owning user (`0o600`). The
    /// `allowAll` mode removes process ancestry checks, but does not cross the
    /// local user boundary.
    var socketFilePermissions: UInt16 {
        switch self {
        case .off, .cmuxOnly, .automation, .password, .allowAll:
            return 0o600
        }
    }

    /// Whether this mode requires a password handshake before commands are accepted.
    var requiresPasswordAuth: Bool {
        self == .password
    }
}
