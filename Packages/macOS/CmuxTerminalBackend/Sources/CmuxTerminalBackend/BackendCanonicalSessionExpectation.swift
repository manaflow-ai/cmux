/// Identity fences required when opening one canonical backend session.
public struct BackendCanonicalSessionExpectation: Equatable, Sendable {
    /// The app-scoped logical session name.
    public let session: String

    /// A readiness-proven authority, when the caller already performed a trusted probe.
    public let authority: BackendAuthority?

    /// A readiness-proven process identifier, when available.
    public let processID: UInt32?

    /// The kernel identity from the exact socket that passed code-signing verification.
    ///
    /// A later canonical connection must match this complete audit token. Matching
    /// only the protocol-reported PID would leave a socket-replacement race.
    public let peerIdentity: BackendPeerIdentity?

    /// Creates one connection expectation.
    public init(
        session: String,
        authority: BackendAuthority? = nil,
        processID: UInt32? = nil,
        peerIdentity: BackendPeerIdentity? = nil
    ) {
        self.session = session
        self.authority = authority
        self.processID = processID
        self.peerIdentity = peerIdentity
    }
}
