import Foundation
import Testing
@testable import CmuxNextAgentPane

/// `_acpmux/status` through the relay (ad349, read-only): the pane renders only `peers[].name`
/// (direct.ts, after initialize). The relay filters the reply to that allowlist at every depth and
/// does not rely on the daemon's redaction.
@MainActor
@Suite(.serialized) struct AgentPaneStatusReplyTests {
    nonisolated static let initialize = #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#

    /// A daemon reply with everything the pane must never see.
    nonisolated static let dirty = #"""
    {"webUrl":"http://127.0.0.1:4700/?token=secret-web","token":"secret-token","localAppToken":"secret-local",
     "version":"9.9","pid":42,"unknown":{"name":"nested-secret","token":"secret-nested"},
     "peers":[{"name":"studio","url":"ssh://alice:hunter2@studio.local:22","token":"secret-peer","extra":{"name":"x"}},
              {"name":"laptop","webUrl":"http://laptop:4700/?token=secret-laptop"},
              {"url":"ssh://bob:pw@nameless"},
              "not-an-object"]}
    """#

    @Test func theStatusReplyReachesThePaneWithOnlyTheFieldsItRenders() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        server.answer("_acpmux/status", with: Self.dirty.replacingOccurrences(of: "\n", with: ""))
        let transport = AgentPaneTransport()
        var received: [String] = []
        transport.deliver = { event, done in received += event.frames; done() }
        let id = try await transport.open(AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil))
        _ = await transport.send(connection: id, frames: [Self.initialize])
        #expect(await transport.send(connection: id, frames: [#"{"jsonrpc":"2.0","id":7,"method":"_acpmux/status","params":{}}"#]) == nil)
        func reply() -> String? { received.first { $0.contains(#""id":7"#) } }
        for _ in 0..<1000 where reply() == nil { try? await Task.sleep(for: .milliseconds(5)) }
        let text = try #require(reply())
        for secret in ["secret", "webUrl", "token", "hunter2", "alice", "bob", "ssh://", "url", "unknown", "version", "pid", "extra",
                       "not-an-object"] {
            #expect(!text.contains(secret), "\(secret) in \(text)")
        }
        let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let result = try #require(object["result"] as? [String: Any])
        #expect(Set(result.keys) == ["peers"])
        let peers = try #require(result["peers"] as? [[String: Any]])
        #expect(peers.compactMap { $0["name"] as? String } == ["studio", "laptop"])
        #expect(peers.allSatisfy { Set($0.keys) == ["name"] })
    }

    @Test func aStatusRequestWithParamsIsRefused() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        let transport = AgentPaneTransport()
        transport.deliver = { _, done in done() }
        let id = try await transport.open(AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil))
        _ = await transport.send(connection: id, frames: [Self.initialize])
        #expect(await transport.send(connection: id, frames: [#"{"jsonrpc":"2.0","id":8,"method":"_acpmux/status","params":{"verbose":true}}"#])
            == .intentInvalid)
    }
}
