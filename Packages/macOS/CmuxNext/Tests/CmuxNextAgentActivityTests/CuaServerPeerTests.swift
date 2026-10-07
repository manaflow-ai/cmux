@testable import CmuxNextAgentActivity
import Darwin
import Foundation
import Testing

/// The app checks that the CUA helper socket's server runs as the expected
/// uid before it sends a request (and the token in it): an impostor server
/// never receives the token.
@Suite struct CuaServerPeerTests {
    @Test func aServerOfAnotherUIDNeverReceivesTheRequest() async throws {
        let host = try FakeCuaHost { _ in ["ok": true, "result": [:]] }
        defer { host.close() }
        let line = Data(#"{"method":"permissions_status","auth_token":"secret"}"#.utf8 + [0x0A])
        await #expect(throws: AgentActivitySourceError.self) {
            _ = try await AgentActivityLineConnection.oneShot(path: host.path, send: line, deadline: .seconds(2),
                                                             expectedServerUID: geteuid() &+ 1)
        }
        // Give a late write time to land before checking nothing arrived.
        try await Task.sleep(for: .milliseconds(200))
        #expect(host.received.isEmpty, "the request (and its token) reached a server of another uid")
    }

    @Test func aServerOfThisUserGetsTheRequest() async throws {
        let host = try FakeCuaHost { _ in ["ok": true, "result": ["fine": true]] }
        defer { host.close() }
        let line = Data(#"{"method":"permissions_status"}"#.utf8 + [0x0A])
        let reply = try await AgentActivityLineConnection.oneShot(path: host.path, send: line, deadline: .seconds(2),
                                                                 expectedServerUID: geteuid())
        #expect(!reply.isEmpty)
        #expect(host.received.count == 1)
    }
}
