import Foundation
import Testing
@testable import CmuxRemoteConnections

@Suite struct MobileRemoteSSHConnectionTests {
    @Test func missingHostChallengeCannotLoadCredential() async throws {
        let connector = FakeConnector(challenge: nil)
        let recorder = LoadRecorder()
        let coordinator = MobileRemoteSSHConnectionCoordinator(
            accountGate: try await authenticatedGate(), connector: connector,
            hostKeyApprover: { _, _ in .accept }
        )
        await #expect(throws: (any Error).self) {
            _ = try await coordinator.connect(profile: profile(), credential: .init {
                await recorder.mark()
                return .password("synthetic-password")
            })
        }
        #expect(await recorder.loaded == false)
    }

    @Test func signOutDuringHostApprovalCannotLoadCredential() async throws {
        let gate = try await authenticatedGate()
        let recorder = LoadRecorder()
        let connector = FakeConnector(challenge: try .init(
            profileID: profileID, algorithm: "ssh-ed25519", fingerprint: "SHA256:test"
        ))
        let coordinator = MobileRemoteSSHConnectionCoordinator(
            accountGate: gate, connector: connector,
            hostKeyApprover: { _, _ in await gate.clear(); return .accept }
        )
        await #expect(throws: (any Error).self) {
            _ = try await coordinator.connect(profile: profile(), credential: .init {
                await recorder.mark()
                return .password("synthetic-password")
            })
        }
        #expect(await recorder.loaded == false)
    }

    @Test func signedOutBlocksConnectorAndCredentialLoading() async throws {
        let connector = FakeConnector(challenge: nil)
        let gate = MobileRemoteAccountGate()
        let coordinator = MobileRemoteSSHConnectionCoordinator(
            accountGate: gate,
            connector: connector,
            hostKeyApprover: { _, _ in .accept }
        )
        let recorder = LoadRecorder()
        await #expect(throws: MobileRemoteAccountGateError.authenticationRequired) {
            _ = try await coordinator.connect(
                profile: profile(),
                credential: MobileRemoteSSHCredentialSource {
                    await recorder.mark()
                    return .password("secret")
                }
            )
        }
        #expect(await recorder.loaded == false)
        #expect(await connector.connectCount == 0)
    }

    @Test func hostKeyMustBeAcceptedBeforeCredentialLoads() async throws {
        let gate = try await authenticatedGate()
        let connector = FakeConnector(
            challenge: try MobileRemoteSSHHostKeyChallenge(
                profileID: profileID, algorithm: "ssh-ed25519",
                fingerprint: "SHA256:test"
            )
        )
        let coordinator = MobileRemoteSSHConnectionCoordinator(
            accountGate: gate,
            connector: connector,
            hostKeyApprover: { _, _ in .accept }
        )
        let recorder = LoadRecorder()
        _ = try await coordinator.connect(
            profile: profile(),
            credential: MobileRemoteSSHCredentialSource {
                await recorder.mark()
                return .password("secret")
            }
        )
        #expect(await recorder.loaded)
        #expect(await connector.credentialWasLoaded)
        #expect(await connector.accountID == "account-1")
    }

    @Test func rejectedHostKeyStopsBeforeCredentialAndSession() async throws {
        let gate = try await authenticatedGate()
        let connector = FakeConnector(
            challenge: try MobileRemoteSSHHostKeyChallenge(
                profileID: profileID, algorithm: "ssh-ed25519",
                fingerprint: "SHA256:unexpected"
            )
        )
        let coordinator = MobileRemoteSSHConnectionCoordinator(
            accountGate: gate,
            connector: connector,
            hostKeyApprover: { _, _ in .reject }
        )
        let recorder = LoadRecorder()
        await #expect(throws: MobileRemoteSSHError.hostKeyRejected) {
            _ = try await coordinator.connect(
                profile: profile(),
                credential: MobileRemoteSSHCredentialSource {
                    await recorder.mark()
                    return .password("secret")
                }
            )
        }
        #expect(await recorder.loaded == false)
        #expect(await connector.credentialWasLoaded == false)
    }

    @Test func nonSSHCarriersCannotUseSSHCoordinator() async throws {
        let gate = try await authenticatedGate()
        let connector = FakeConnector(challenge: nil)
        let coordinator = MobileRemoteSSHConnectionCoordinator(
            accountGate: gate,
            connector: connector,
            hostKeyApprover: { _, _ in .accept }
        )
        let mosh = try MobileRemoteProfile(
            id: profileID, host: "example.com", username: "alice", carrier: .mosh
        )
        await #expect(throws: MobileRemoteSSHError.unsupportedCarrier(.mosh)) {
            _ = try await coordinator.connect(
                profile: mosh,
                credential: MobileRemoteSSHCredentialSource { nil }
            )
        }
        #expect(await connector.connectCount == 0)
    }

    @Test func controllerPersistsAnApprovedAskKeyAndSkipsThePromptNextTime() async throws {
        let gate = try await authenticatedGate()
        let connector = FakeConnector(challenge: try .init(
            profileID: profileID, algorithm: "ssh-ed25519", fingerprint: "SHA256:controller"
        ))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("controller-host-\(UUID().uuidString).json")
        let store = try MobileRemoteHostKeyStore(databaseURL: url, accountID: "account-1")
        let controller = MobileRemoteConnectionController(
            accountGate: gate, connector: connector, hostKeyStoreProvider: { _ in store }
        )
        let profile = try profile()
        let first = try await controller.connect(
            profile: profile,
            credential: MobileRemoteSSHCredentialSource { .password("secret") },
            approveUnknownHost: { _ in true }
        )
        await first.close()
        let second = try await controller.connect(
            profile: profile,
            credential: MobileRemoteSSHCredentialSource { .password("secret") },
            approveUnknownHost: { _ in
                Issue.record("remembered host key should not ask again")
                return false
            }
        )
        await second.close()
        #expect(await store.observation(for: profileID)?.fingerprint == "SHA256:controller")
    }

    @Test func controllerStrictPolicyRejectsUnknownKeysBeforeCredentialLoad() async throws {
        let gate = try await authenticatedGate()
        let connector = FakeConnector(challenge: try .init(
            profileID: profileID, algorithm: "ssh-ed25519", fingerprint: "SHA256:strict"
        ))
        let store = try MobileRemoteHostKeyStore(
            databaseURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("controller-strict-\(UUID().uuidString).json"),
            accountID: "account-1"
        )
        let controller = MobileRemoteConnectionController(
            accountGate: gate, connector: connector, hostKeyStoreProvider: { _ in store }
        )
        let strictProfile = try MobileRemoteProfile(
            id: profileID, host: "example.com", username: "alice",
            carrier: .ssh, authentication: .password, hostKeyPolicy: .strict
        )
        let recorder = LoadRecorder()
        await #expect(throws: MobileRemoteSSHError.hostKeyRejected) {
            _ = try await controller.connect(
                profile: strictProfile,
                credential: MobileRemoteSSHCredentialSource {
                    await recorder.mark()
                    return .password("secret")
                },
                approveUnknownHost: { _ in true }
            )
        }
        #expect(await recorder.loaded == false)
    }

    @Test func signOutWhileCredentialLoadsPreventsAuthentication() async throws {
        let gate = try await authenticatedGate()
        let connector = FakeConnector(challenge: try .init(
            profileID: profileID, algorithm: "ssh-ed25519", fingerprint: "SHA256:test"
        ))
        let coordinator = MobileRemoteSSHConnectionCoordinator(
            accountGate: gate, connector: connector, hostKeyApprover: { _, _ in .accept }
        )
        await #expect(throws: MobileRemoteAccountGateError.authenticationRequired) {
            _ = try await coordinator.connect(profile: profile(), credential: .init {
                await gate.clear()
                return .password("synthetic-secret")
            })
        }
        #expect(await connector.credentialWasLoaded == false)
        #expect(await connector.closed)
    }

    @Test func signOutDuringAuthenticationClosesTheProducedSession() async throws {
        let gate = try await authenticatedGate()
        let connector = FakeConnector(challenge: try .init(
            profileID: profileID, algorithm: "ssh-ed25519", fingerprint: "SHA256:test"
        ), onAuthenticate: { await gate.clear() })
        let coordinator = MobileRemoteSSHConnectionCoordinator(
            accountGate: gate, connector: connector, hostKeyApprover: { _, _ in .accept }
        )
        await #expect(throws: MobileRemoteAccountGateError.authenticationRequired) {
            _ = try await coordinator.connect(profile: profile(), credential: .init {
                .password("synthetic-secret")
            })
        }
        #expect(await connector.closed)
        #expect(await connector.sessionClosed)
    }

    @Test func differentProfileHostKeyCannotReachApprovalOrCredential() async throws {
        let recorder = LoadRecorder()
        let connector = FakeConnector(challenge: try .init(
            profileID: UUID(), algorithm: "ssh-ed25519", fingerprint: "SHA256:test"
        ))
        let coordinator = MobileRemoteSSHConnectionCoordinator(
            accountGate: try await authenticatedGate(), connector: connector,
            hostKeyApprover: { _, _ in
                Issue.record("Wrong-profile key must not be presented for approval")
                return .accept
            }
        )
        await #expect(throws: MobileRemoteSSHError.invalidHostKeyChallenge) {
            _ = try await coordinator.connect(profile: profile(), credential: .init {
                await recorder.mark()
                return .password("synthetic-secret")
            })
        }
        #expect(await recorder.loaded == false)
        #expect(await connector.closed)
    }

    private func authenticatedGate() async throws -> MobileRemoteAccountGate {
        let gate = MobileRemoteAccountGate()
        try await gate.setAuthenticatedAccount(
            accountID: "account-1", sessionGeneration: 1
        )
        return gate
    }

    private func profile() throws -> MobileRemoteProfile {
        try MobileRemoteProfile(
            id: profileID, host: "example.com", username: "alice",
            carrier: .ssh, authentication: .password
        )
    }

    private let profileID = UUID(uuidString: "C2C4EC54-58B9-47C6-BB45-21774579B13B")!
}

private actor FakeConnector: MobileRemoteSSHConnecting {
    let challenge: MobileRemoteSSHHostKeyChallenge?
    private(set) var connectCount = 0
    private(set) var credentialWasLoaded = false
    private(set) var accountID: String?
    private(set) var closed = false
    private(set) var sessionClosed = false
    let onAuthenticate: @Sendable () async -> Void

    init(challenge: MobileRemoteSSHHostKeyChallenge?, onAuthenticate: @escaping @Sendable () async -> Void = {}) {
        self.challenge = challenge
        self.onAuthenticate = onAuthenticate
    }

    func handshake(_ request: MobileRemoteSSHConnectionRequest) async throws -> any MobileRemoteSSHHandshake {
        connectCount += 1
        accountID = request.account.accountID
        return FakeHandshake(challenge: challenge, owner: self)
    }

    func didAuthenticate() async {
        credentialWasLoaded = true
        await onAuthenticate()
    }
    func didClose() { closed = true }
    func didCloseSession() { sessionClosed = true }
}

private actor FakeHandshake: MobileRemoteSSHHandshake {
    let challenge: MobileRemoteSSHHostKeyChallenge?
    let owner: FakeConnector
    init(challenge: MobileRemoteSSHHostKeyChallenge?, owner: FakeConnector) {
        self.challenge = challenge
        self.owner = owner
    }
    func hostKey() throws -> MobileRemoteSSHHostKeyChallenge {
        guard let challenge else { throw MobileRemoteSSHError.invalidHostKeyChallenge }
        return challenge
    }
    func authenticate(credential: MobileRemoteCredentialMaterial?, respondToKeyboardChallenge: @escaping @Sendable (MobileRemoteSSHKeyboardChallenge) async throws -> [String]) async throws -> any MobileRemoteSSHSession {
        await owner.didAuthenticate()
        return FakeSession(owner: owner)
    }
    func close() async { await owner.didClose() }
}

private struct FakeSession: MobileRemoteSSHSession {
    let owner: FakeConnector
    func output() -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream { continuation in continuation.finish() }
    }
    func sendInput(_ data: Data) async throws {}
    func resize(columns: Int, rows: Int) async throws {}
    func close() async { await owner.didCloseSession() }
}

private actor LoadRecorder {
    private(set) var loaded = false
    func mark() { loaded = true }
}
