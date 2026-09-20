public import Foundation

/// Host-key material observed during the SSH handshake.
///
/// The observation is untrusted until the coordinator's approver accepts it.
public struct MobileRemoteSSHHostKeyChallenge: Equatable, Sendable {
    public let profileID: UUID
    public let algorithm: String
    public let fingerprint: String

    public init(profileID: UUID, algorithm: String, fingerprint: String) throws {
        guard !algorithm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !fingerprint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !algorithm.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !fingerprint.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw MobileRemoteSSHError.invalidHostKeyChallenge
        }
        self.profileID = profileID
        self.algorithm = algorithm
        self.fingerprint = fingerprint
    }
}

/// Decision returned after a user or trusted host-key store evaluates a challenge.
public enum MobileRemoteSSHHostKeyDecision: Equatable, Sendable {
    case accept
    case reject
}

/// A lazy source for one profile's device-local credential.
///
/// The SSH engine invokes the closure only after host-key approval.
public struct MobileRemoteSSHCredentialSource: Sendable {
    private let loader: @Sendable () async throws -> MobileRemoteCredentialMaterial?

    public init(
        load: @escaping @Sendable () async throws -> MobileRemoteCredentialMaterial?
    ) {
        self.loader = load
    }

    public func load() async throws -> MobileRemoteCredentialMaterial? {
        try await loader()
    }
}

/// The request passed from the account and trust gate into a native SSH engine.
public struct MobileRemoteSSHConnectionRequest: Sendable {
    public let account: MobileRemoteAuthenticatedAccount
    public let profile: MobileRemoteProfile
    public let credential: MobileRemoteSSHCredentialSource

    public init(
        account: MobileRemoteAuthenticatedAccount,
        profile: MobileRemoteProfile,
        credential: MobileRemoteSSHCredentialSource
    ) throws {
        try profile.validate()
        self.account = account
        self.profile = profile
        self.credential = credential
    }
}

/// A native SSH session consumed by the terminal renderer.
public protocol MobileRemoteSSHSession: Sendable {
    func output() -> AsyncThrowingStream<Data, any Error>
    func sendInput(_ data: Data) async throws
    func resize(columns: Int, rows: Int) async throws
    func close() async
}

/// Engine boundary for a maintained SSH implementation.
///
/// The implementation must perform host-key negotiation and invoke the
/// decision callback before calling request.credential.load().
public protocol MobileRemoteSSHConnecting: Sendable {
    func connect(
        _ request: MobileRemoteSSHConnectionRequest,
        decideHostKey: @escaping @Sendable (
            MobileRemoteSSHHostKeyChallenge
        ) async throws -> MobileRemoteSSHHostKeyDecision
    ) async throws -> any MobileRemoteSSHSession
}

/// Account and trust gate shared by SSH, Mosh bootstrap, and ET bootstrap.
public actor MobileRemoteSSHConnectionCoordinator {
    private let accountGate: MobileRemoteAccountGate
    private let connector: any MobileRemoteSSHConnecting
    private let hostKeyApprover: @Sendable (
        MobileRemoteSSHHostKeyChallenge,
        MobileRemoteHostKeyPolicy
    ) async throws -> MobileRemoteSSHHostKeyDecision

    public init(
        accountGate: MobileRemoteAccountGate,
        connector: any MobileRemoteSSHConnecting,
        hostKeyApprover: @escaping @Sendable (
            MobileRemoteSSHHostKeyChallenge,
            MobileRemoteHostKeyPolicy
        ) async throws -> MobileRemoteSSHHostKeyDecision
    ) {
        self.accountGate = accountGate
        self.connector = connector
        self.hostKeyApprover = hostKeyApprover
    }

    public func connect(
        profile: MobileRemoteProfile,
        credential: MobileRemoteSSHCredentialSource
    ) async throws -> any MobileRemoteSSHSession {
        let account = try await accountGate.requireAccount()
        guard profile.carrier == .ssh || profile.carrier == .automatic else {
            throw MobileRemoteSSHError.unsupportedCarrier(profile.carrier)
        }
        let request = try MobileRemoteSSHConnectionRequest(
            account: account, profile: profile, credential: credential
        )
        return try await connector.connect(request) { [hostKeyApprover] challenge in
            try await hostKeyApprover(challenge, profile.hostKeyPolicy)
        }
    }
}

/// Failures before or during the native SSH boundary.
public enum MobileRemoteSSHError: Error, Equatable, Sendable {
    case authenticationRequired
    case unsupportedCarrier(MobileRemoteCarrier)
    case invalidHostKeyChallenge
    case hostKeyRejected
}
