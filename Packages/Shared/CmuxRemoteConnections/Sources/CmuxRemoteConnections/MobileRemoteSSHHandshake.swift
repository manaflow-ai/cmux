/// An established SSH handshake whose host is not yet trusted.
///
/// Each instance owns one underlying transport and one stable host key.
/// Authentication must use that same transport; changing it requires a new
/// handshake and trust decision. No credential source reaches this interface.
public protocol MobileRemoteSSHHandshake: Sendable {
    /// Reports the actual negotiated key, or fails if no key was obtained.
    /// - Returns: An untrusted observation from this exact handshake.
    /// - Throws: Negotiation, cancellation, or missing-key errors.
    func hostKey() async throws -> MobileRemoteSSHHostKeyChallenge

    /// Authenticates the previously approved handshake.
    /// - Parameter credential: Material loaded only after coordinator approval.
    /// - Returns: Authenticated session owning this transport.
    /// - Throws: Authentication, cancellation, or transport errors.
    func authenticate(credential: MobileRemoteCredentialMaterial?) async throws -> any MobileRemoteSSHSession

    /// Idempotently closes the transport, including any session it produced.
    func close() async
}
