/// A backend transport that exposes the kernel identity of its connected peer.
public protocol BackendPeerIdentityTransport: BackendMessageTransport {
    /// Reads the identity attached to this exact connected socket by the kernel.
    ///
    /// - Returns: The peer process, effective user, and non-reusable audit identity.
    /// - Throws: A transport or operating-system credential lookup error.
    func peerIdentity() async throws -> BackendPeerIdentity
}
