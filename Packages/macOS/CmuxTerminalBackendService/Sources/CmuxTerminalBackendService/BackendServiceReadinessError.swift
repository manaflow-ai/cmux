/// Failures specific to terminal-backend readiness verification.
public enum BackendServiceReadinessError: Error, Equatable, Sendable {
    /// The backend did not complete its handshake before the bounded deadline.
    case timedOut

    /// The socket peer runs under a user other than the current app user.
    case unexpectedPeerUser(expected: UInt32, actual: UInt32)

    /// The backend socket loops back into the current Swift application process.
    case peerRunsInClientProcess(processID: UInt32)

    /// A protocol payload claimed a PID other than the socket's kernel-reported peer.
    case reportedProcessMismatch(kernel: UInt32, reported: UInt32)

    /// The daemon reported a logical session other than the app-scoped session.
    case unexpectedSession(expected: String, actual: String)

    /// The topology snapshot came from a different daemon or persisted session.
    case authorityChanged

    /// The lightweight health revision moved backwards relative to identify.
    case topologyRevisionRegressed(identify: UInt64, health: UInt64)
}
