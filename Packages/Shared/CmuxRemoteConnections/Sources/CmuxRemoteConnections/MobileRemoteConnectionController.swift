import Foundation

/// Account-gated owner for direct SSH and cmux protocol sessions.
///
/// The controller keeps host-key trust and credential loading behind one
/// connection boundary. UI code supplies only the explicit decision for an
/// unknown `ask` key and a lazy credential source; it never constructs a
/// handshake or bypasses the account gate.
public actor MobileRemoteConnectionController: MobileRemoteConnectionServing {
    /// Resolves the exact account-scoped host-key store for a live account.
    public typealias HostKeyStoreProvider = @Sendable (String) async throws -> MobileRemoteHostKeyStore

    private let accountGate: MobileRemoteAccountGate
    private let connector: any MobileRemoteSSHConnecting
    private let hostKeyStoreProvider: HostKeyStoreProvider

    /// Creates a controller for the app composition root.
    /// - Parameters:
    ///   - accountGate: Live cmux account authority required by every session.
    ///   - connector: Native SSH engine.
    ///   - hostKeyStoreProvider: Resolves a store scoped to the authenticated account.
    public init(
        accountGate: MobileRemoteAccountGate,
        connector: any MobileRemoteSSHConnecting,
        hostKeyStoreProvider: @escaping HostKeyStoreProvider
    ) {
        self.accountGate = accountGate
        self.connector = connector
        self.hostKeyStoreProvider = hostKeyStoreProvider
    }

    /// Opens a direct SSH session after host approval and credential gating.
    /// - Parameters:
    ///   - profile: Validated destination and session settings.
    ///   - credential: Lazy credential source; material is requested only after trust.
    ///   - approveUnknownHost: Explicit UI decision for a new `.ask` fingerprint.
    /// - Returns: Authenticated shell or cmux exec session.
    /// - Throws: Account, trust, credential, cancellation, or engine errors.
    public func connect(
        profile: MobileRemoteProfile,
        credential: MobileRemoteSSHCredentialSource,
        approveUnknownHost: @escaping @Sendable (MobileRemoteSSHHostKeyChallenge) async throws -> Bool
    ) async throws -> any MobileRemoteSSHSession {
        let account = try await accountGate.requireAccount()
        let trustStore = try await hostKeyStoreProvider(account.accountID)
        let coordinator = MobileRemoteSSHConnectionCoordinator(
            accountGate: accountGate,
            connector: connector,
            hostKeyApprover: { challenge, policy in
                let remembered = await trustStore.decision(for: challenge, policy: policy)
                if remembered == .accept { return .accept }
                guard policy == .ask, try await approveUnknownHost(challenge) else { return .reject }
                try await trustStore.record(challenge)
                return .accept
            }
        )
        return try await coordinator.connect(profile: profile, credential: credential)
    }
}

/// The UI-facing service boundary for account-gated remote sessions.
public protocol MobileRemoteConnectionServing: Sendable {
    /// Opens one validated remote profile after explicit host approval.
    func connect(
        profile: MobileRemoteProfile,
        credential: MobileRemoteSSHCredentialSource,
        approveUnknownHost: @escaping @Sendable (MobileRemoteSSHHostKeyChallenge) async throws -> Bool
    ) async throws -> any MobileRemoteSSHSession
}
