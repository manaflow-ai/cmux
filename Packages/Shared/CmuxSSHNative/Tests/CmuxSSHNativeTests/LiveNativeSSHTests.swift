import CmuxRemoteConnections
import Foundation
import Testing
@testable import CmuxSSHNative

@Suite struct LiveNativeSSHTests {
    @Test func liveNativeSSHAgainstFixture() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let port = Int(environment["CMUX_NATIVE_SSH_PORT"] ?? ""),
              let password = environment["CMUX_NATIVE_SSH_PASSWORD"],
              let expectedFingerprint = environment["CMUX_NATIVE_SSH_FINGERPRINT"] else {
            return
        }
        let accountGate = MobileRemoteAccountGate(validate: { _ in })
        try await accountGate.setAuthenticatedAccount(accountID: "fixture-account", sessionGeneration: 1)
        let connector = MobileRemoteNativeSSHConnector(configuration: .init(connectTimeout: .seconds(10)))
        let coordinator = MobileRemoteSSHConnectionCoordinator(
            accountGate: accountGate, connector: connector,
            hostKeyApprover: { challenge, _ in
                challenge.fingerprint == expectedFingerprint ? .accept : .reject
            }
        )
        let profile = try MobileRemoteProfile(
            id: UUID(), host: "127.0.0.1", port: port, username: "fixture",
            carrier: .ssh, authentication: .password
        )
        let session = try await coordinator.connect(
            profile: profile,
            credential: MobileRemoteSSHCredentialSource { .password(password) }
        )
        let stream = session.output()
        try await session.sendInput(Data("ping\n".utf8))
        var output = Data()
        for try await chunk in stream {
            output.append(chunk)
            if output.contains(Data("PONG".utf8)) { break }
        }
        #expect(output.contains(Data("PONG".utf8)))
        let sftp = try #require(session as? any MobileRemoteSFTPProviding)
        #expect(try await sftp.readFile(path: "/fixture.txt", maxBytes: 1024) == Data("fixture-sftp\n".utf8))
        #expect(try await sftp.listDirectory(path: "/", maxEntries: 100, maxBytes: 16 * 1024).contains("fixture.txt"))
        await session.close()
    }

    @Test func liveKeyboardInteractiveAgainstFixture() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let port = Int(environment["CMUX_NATIVE_SSH_PORT"] ?? "") else { return }
        let gate = MobileRemoteAccountGate(validate: { _ in })
        try await gate.setAuthenticatedAccount(accountID: "fixture-account", sessionGeneration: 1)
        let coordinator = MobileRemoteSSHConnectionCoordinator(
            accountGate: gate, connector: MobileRemoteNativeSSHConnector(),
            hostKeyApprover: { _, _ in .accept }
        )
        let profile = try MobileRemoteProfile(
            id: UUID(), host: "127.0.0.1", port: port, username: "fixture",
            carrier: .ssh, authentication: .keyboardInteractive
        )
        let session = try await coordinator.connect(
            profile: profile,
            credential: MobileRemoteSSHCredentialSource(
                load: { nil },
                respondToKeyboardChallenge: { challenge in
                #expect(challenge.prompts.count == 1)
                return challenge.prompts.first?.text.contains("First") == true
                    ? ["first-factor"] : ["second-factor"]
                }
            )
        )
        await session.close()
    }

    @Test func liveEd25519KeyAuthenticationAgainstFixture() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let port = Int(environment["CMUX_NATIVE_SSH_PORT"] ?? ""),
              let keyBase64 = environment["CMUX_NATIVE_SSH_ED25519_KEY"],
              let key = Data(base64Encoded: keyBase64) else { return }
        let gate = MobileRemoteAccountGate(validate: { _ in })
        try await gate.setAuthenticatedAccount(accountID: "fixture-account", sessionGeneration: 1)
        let coordinator = MobileRemoteSSHConnectionCoordinator(
            accountGate: gate, connector: MobileRemoteNativeSSHConnector(),
            hostKeyApprover: { _, _ in .accept }
        )
        let profile = try MobileRemoteProfile(
            id: UUID(), host: "127.0.0.1", port: port, username: "fixture",
            carrier: .ssh, authentication: .publicKey
        )
        let session = try await coordinator.connect(
            profile: profile,
            credential: MobileRemoteSSHCredentialSource { .privateKey(key, passphrase: nil) }
        )
        await session.close()
    }
}
