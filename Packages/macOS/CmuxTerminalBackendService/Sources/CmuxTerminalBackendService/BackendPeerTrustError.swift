/// Failures while authenticating the live backend process.
public enum BackendPeerTrustError: Error, Equatable, Sendable {
    /// The reusable socket PID disagreed with the socket's audit token.
    case auditTokenProcessMismatch(socket: UInt32, auditToken: Int32)

    /// The socket credential UID disagreed with the socket's audit token.
    case auditTokenUserMismatch(socket: UInt32, auditToken: UInt32)

    /// A macOS Security framework operation failed.
    case security(operation: String, status: Int32)

    /// macOS could not resolve an executable for the live peer audit identity.
    case executableUnavailable(processID: UInt32, processIDVersion: Int32)

    /// The signed helper identifier does not match cmux's dedicated identifier.
    case unexpectedSigningIdentifier(expected: String, actual: String?)

    /// A production helper was not signed by the app's Developer ID team.
    case unexpectedTeamIdentifier(expected: String, actual: String?)

    /// The running helper did not come from this exact app bundle path.
    case unexpectedExecutable(expected: String, actual: String)
}
