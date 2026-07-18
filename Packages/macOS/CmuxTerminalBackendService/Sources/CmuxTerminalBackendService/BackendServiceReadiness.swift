public import CmuxTerminalBackend

/// Proven protocol readiness for one running terminal backend.
public struct BackendServiceReadiness: Equatable, Sendable {
    /// The running daemon and persisted session identities.
    public let authority: BackendAuthority

    /// The logical cmux-tui session name reported by the daemon.
    public let session: String

    /// The daemon process identifier verified against the connected socket.
    public let processID: UInt32

    /// The effective user identifier verified against the connected socket.
    public let userID: UInt32

    /// Kernel identity of the exact socket peer that passed trust verification.
    public let peerIdentity: BackendPeerIdentity

    /// Code-signing evidence for the same kernel-identified process.
    public let peerTrust: BackendPeerTrustEvidence

    /// The canonical topology revision observed by the readiness snapshot.
    public let topologyRevision: UInt64

    /// Explicit mutation authority negotiated by the identify-first probe.
    public let compatibility: BackendCompatibilityResult

    /// Creates a readiness proof from one successful kernel and protocol handshake.
    ///
    /// - Parameters:
    ///   - authority: The running daemon and persisted session identities.
    ///   - session: The logical cmux-tui session name.
    ///   - processID: The kernel-verified daemon process identifier.
    ///   - userID: The kernel-verified daemon effective user identifier.
    ///   - peerTrust: The verified code identity and live executable path.
    ///   - topologyRevision: The canonical topology revision observed by the probe.
    ///   - compatibility: The identify-first compatibility result.
    public init(
        authority: BackendAuthority,
        session: String,
        processID: UInt32,
        userID: UInt32,
        peerIdentity: BackendPeerIdentity,
        peerTrust: BackendPeerTrustEvidence,
        topologyRevision: UInt64,
        compatibility: BackendCompatibilityResult
    ) {
        self.authority = authority
        self.session = session
        self.processID = processID
        self.userID = userID
        self.peerIdentity = peerIdentity
        self.peerTrust = peerTrust
        self.topologyRevision = topologyRevision
        self.compatibility = compatibility
    }
}
