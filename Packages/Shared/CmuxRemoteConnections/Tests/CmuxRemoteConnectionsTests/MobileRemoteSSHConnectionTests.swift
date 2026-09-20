import Foundation
import Testing
@testable import CmuxRemoteConnections

@Suite struct MobileRemoteSSHConnectionTests {
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
        await #expect(throws: FakeConnectorError.hostKeyRejected) {
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

    init(challenge: MobileRemoteSSHHostKeyChallenge?) {
        self.challenge = challenge
    }

    func connect(
        _ request: MobileRemoteSSHConnectionRequest,
        decideHostKey: @escaping @Sendable (
            MobileRemoteSSHHostKeyChallenge
        ) async throws -> MobileRemoteSSHHostKeyDecision
    ) async throws -> any MobileRemoteSSHSession {
        connectCount += 1
        accountID = request.account.accountID
        if let challenge {
            guard try await decideHostKey(challenge) == .accept else {
                throw FakeConnectorError.hostKeyRejected
            }
        }
        credentialWasLoaded = true
        _ = try await request.credential.load()
        return FakeSession()
    }
}

private enum FakeConnectorError: Error, Equatable {
    case hostKeyRejected
}

private struct FakeSession: MobileRemoteSSHSession {
    func output() -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream { continuation in continuation.finish() }
    }
    func sendInput(_ data: Data) async throws {}
    func resize(columns: Int, rows: Int) async throws {}
    func close() async {}
}

private actor LoadRecorder {
    private(set) var loaded = false
    func mark() { loaded = true }
}
