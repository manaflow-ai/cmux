/// Owns handshake, host approval, credential loading, and authentication order.
///
/// The engine receives no credential source during negotiation. Account state
/// is revalidated across every suspension before secrets are handed to the
/// engine, and failures close any acquired native resources. Live-session
/// revocation after return belongs to the session lifecycle owner.
public actor MobileRemoteSSHConnectionCoordinator {
    private let accountGate: MobileRemoteAccountGate
    private let connector: any MobileRemoteSSHConnecting
    private let hostKeyApprover: @Sendable (
        MobileRemoteSSHHostKeyChallenge, MobileRemoteHostKeyPolicy
    ) async throws -> MobileRemoteSSHHostKeyDecision

    /// Composes the engine with the live account owner and trust UI/store.
    /// - Parameters:
    ///   - accountGate: Validates the current cmux account session.
    ///   - connector: Native engine that opens a credential-free handshake.
    ///   - hostKeyApprover: Evaluates the exact key under the profile's trust policy.
    public init(
        accountGate: MobileRemoteAccountGate,
        connector: any MobileRemoteSSHConnecting,
        hostKeyApprover: @escaping @Sendable (
            MobileRemoteSSHHostKeyChallenge, MobileRemoteHostKeyPolicy
        ) async throws -> MobileRemoteSSHHostKeyDecision
    ) {
        self.accountGate = accountGate
        self.connector = connector
        self.hostKeyApprover = hostKeyApprover
    }

    /// Opens a session with account and host verification preceding credential use.
    /// - Parameters:
    ///   - profile: Destination and session settings.
    ///   - credential: Lazy local/provider credential source, kept from the handshake.
    /// - Returns: An authenticated session after a final account check.
    /// - Throws: Cancellation, account, trust, credential, or engine errors.
    public func connect(
        profile: MobileRemoteProfile,
        credential: MobileRemoteSSHCredentialSource
    ) async throws -> any MobileRemoteSSHSession {
        try Task.checkCancellation()
        guard profile.carrier == .ssh || profile.carrier == .automatic else {
            throw MobileRemoteSSHError.unsupportedCarrier(profile.carrier)
        }
        let account = try await accountGate.requireAccount()
        let request = try MobileRemoteSSHConnectionRequest(account: account, profile: profile)
        try Task.checkCancellation()
        let handshake = try await connector.handshake(request)
        do {
            try await accountGate.requireCurrent(account)
            try Task.checkCancellation()
            let challenge = try await handshake.hostKey()
            guard challenge.profileID == profile.id else {
                throw MobileRemoteSSHError.invalidHostKeyChallenge
            }
            try await accountGate.requireCurrent(account)
            try Task.checkCancellation()
            let decision = try await hostKeyApprover(challenge, profile.hostKeyPolicy)
            try await accountGate.requireCurrent(account)
            try Task.checkCancellation()
            guard decision == .accept else { throw MobileRemoteSSHError.hostKeyRejected }
            let material = try await credential.load()
            try await accountGate.requireCurrent(account)
            try Task.checkCancellation()
            let session = try await handshake.authenticate(credential: material)
            do {
                try await accountGate.requireCurrent(account)
                try Task.checkCancellation()
                return session
            } catch {
                await session.close()
                throw error
            }
        } catch {
            await handshake.close()
            throw error
        }
    }
}
