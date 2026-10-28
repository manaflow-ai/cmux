@testable import CmuxNextControl
import CmuxNextSettings
import Darwin
import Foundation
import Testing

/// Other cmux builds listen on names in the shared /tmp, where any user can
/// create a socket first. The peer client writes a request only to a socket
/// whose server runs as this user, read on the connection itself.
@Suite(.serialized, .timeLimit(.minutes(1))) struct ControlPeerClientOwnerTests {
    func makeServer() throws -> ControlSocketServer {
        let router = ControlRouter(identity: testIdentity(), executor: CountingExecutor(), configuration: .loadTolerant)
        router.snapshots.publish { $0 = .sample() }
        let server = ControlSocketServer(configuration: .init(path: temporarySocketPath(), accessMode: .automation), router: router)
        try server.start()
        return server
    }

    @Test func aServerOfThisUserAnswers() async throws {
        let server = try makeServer()
        defer { server.stop() }
        _ = try await ControlPeerClient.request(path: server.configuration.path, method: "system.ping")
    }

    @Test func aServerOfAnotherUserIsRefusedBeforeAnyRequest() async throws {
        let server = try makeServer()
        defer { server.stop() }
        await #expect(throws: ControlPeerClient.Failure.notOwnUser) {
            _ = try await ControlPeerClient.request(path: server.configuration.path, method: "system.ping",
                                                    expectedUID: getuid() &+ 1)
        }
    }
}
