import Foundation
import Testing
@testable import CmuxNextAgentPane

/// cx-6o0 at the relay boundary (the page's frames into ``AgentPaneTransport``, out to acpmux): a
/// page frame carries only `jsonrpc`, `id`, `method` and `params`, as the pane sends them
/// (direct.ts). Any other top-level key (a `result` or `error` that makes a request read as a
/// response, a `session` the daemon might act on) is refused before it reaches acpmux.
@Suite(.serialized)
@MainActor
struct AgentPaneFrameKeysRelayTests {
    static func initialize(id: Int, extra: String = "") -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"method":"initialize","params":{}\#(extra)}"#
    }

    static func harnesses(id: Int, extra: String = "") -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"method":"_acpmux/harnesses","params":{}\#(extra)}"#
    }

    @Test func aFrameWithAnUnknownTopLevelKeyNeverReachesAcpmux() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        let inbox = AgentPaneRelayedAllowTests.PageInbox()
        let transport = AgentPaneTransport()
        transport.deliver = { event, done in inbox.deliver(event.frames); done() }
        let id = try await transport.open(AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil))
        let reached = { server.peers.first?.frames ?? [] }

        #expect(await transport.send(connection: id, frames: [Self.initialize(id: 10, extra: #","session":"s""#)]) == .invalidFrame,
                "the first frame with a session key")
        #expect(await transport.send(connection: id, frames: [Self.initialize(id: 0)]) == nil)
        _ = await inbox.frame(containing: #""id":0"#)

        for (n, extra) in [#","result":{}"#, #","error":{"code":1,"message":"m"}"#, #","session":"s""#].enumerated() {
            #expect(await transport.send(connection: id, frames: [Self.harnesses(id: n + 1, extra: extra)]) == .invalidFrame,
                    "a request with \(extra)")
        }
        #expect(!reached().contains { $0.contains("_acpmux/harnesses") }, "a refused frame reached acpmux: \(reached())")

        #expect(await transport.send(connection: id, frames: [Self.harnesses(id: 9)]) == nil)
        _ = await inbox.frame(containing: #""id":9"#)
        #expect(reached().filter { $0.contains("_acpmux/harnesses") }.count == 1)
    }
}
