
public extension SocketControlMode {
    /// The POSIX permission bits to apply to the socket file for this mode.
    ///
    /// `allowAll` opens the socket to every local user (`0o666`); every other mode restricts
    /// it to the owner (`0o600`).
    var socketFilePermissions: UInt16 {
        switch self {
        case .allowAll:
            return 0o666
        case .off, .cmuxOnly, .automation, .password:
            return 0o600
        }
    }

    /// Whether this mode requires a password handshake before commands are accepted.
    var requiresPasswordAuth: Bool {
        self == .password
    }
}
