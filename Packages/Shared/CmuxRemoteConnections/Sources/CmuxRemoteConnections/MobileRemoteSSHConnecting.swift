/// Opens credential-free handshakes using an in-process SSH implementation.
public protocol MobileRemoteSSHConnecting: Sendable {
    /// Negotiates SSH without loading passwords, signing keys, or prompting for auth.
    /// - Parameter request: Validated, account-scoped destination parameters.
    /// - Returns: One unauthenticated connection with a stable host key.
    /// - Throws: Transport or negotiation errors; implementations release partial resources.
    func handshake(_ request: MobileRemoteSSHConnectionRequest) async throws -> any MobileRemoteSSHHandshake
}
