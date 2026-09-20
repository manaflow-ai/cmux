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
            Issue.record("Live fixture environment was not provided")
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
        await session.close()
    }
}
