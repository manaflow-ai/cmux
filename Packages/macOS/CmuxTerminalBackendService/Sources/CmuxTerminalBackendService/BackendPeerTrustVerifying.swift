public import CmuxTerminalBackend

/// Verifies that a kernel-identified socket peer is the signed cmux backend.
public protocol BackendPeerTrustVerifying: Sendable {
    /// Validates the live peer process and returns inspectable trust evidence.
    ///
    /// - Parameter identity: The identity read from the exact protocol socket.
    /// - Returns: Code-signing and executable-path evidence.
    /// - Throws: A code-signing, process-inspection, or policy error.
    func verify(_ identity: BackendPeerIdentity) throws -> BackendPeerTrustEvidence
}
