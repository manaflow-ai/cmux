/// Credential-free parameters allowed to reach the SSH handshake engine.
public struct MobileRemoteSSHConnectionRequest: Sendable {
    /// The authenticated app account; never sent as an SSH credential.
    public let account: MobileRemoteAuthenticatedAccount
    /// Validated destination, routing, and requested remote session.
    public let profile: MobileRemoteProfile

    /// Creates handshake parameters without a credential or loader.
    /// - Parameters:
    ///   - account: Identity captured from the live account gate.
    ///   - profile: Connection settings to validate before opening a socket.
    /// - Throws: Profile validation errors.
    public init(account: MobileRemoteAuthenticatedAccount, profile: MobileRemoteProfile) throws {
        try profile.validate()
        self.account = account
        self.profile = profile
    }
}
