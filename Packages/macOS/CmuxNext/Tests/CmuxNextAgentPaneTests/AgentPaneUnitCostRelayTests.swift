import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Exercise the native transport that a direct daemon or component test bypasses.
@Suite(.serialized)
@MainActor
struct AgentPaneUnitCostRelayTests {
    @Test(.timeLimit(.minutes(1))) func calculatorInputsReachTheDaemon() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        let inbox = AgentPaneRelayedAllowTests.PageInbox()
        let transport = AgentPaneTransport()
        transport.deliver = { event, done in inbox.deliver(event.frames); done() }
        let id = try await transport.open(AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil))
        #expect(await transport.send(connection: id, frames: [#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#]) == nil)
        let frame = #"{"jsonrpc":"2.0","id":1,"method":"_acpmux/unit_cost","params":{"seconds":"900","hourlyUsd":"1,5","busyPercent":"37,5"}}"#
        #expect(await transport.send(connection: id, frames: [frame]) == nil)
        _ = await inbox.frame(containing: #""id":1"#)
        let sent = try #require(server.peers.first?.frames.first { $0.contains("_acpmux/unit_cost") })
        let object = try JSONSerialization.jsonObject(with: Data(sent.utf8)) as? [String: Any]
        let params = try #require(object?["params"] as? [String: Any])
        #expect(params as NSDictionary == ["seconds": "900", "hourlyUsd": "1,5", "busyPercent": "37,5"] as NSDictionary)
        let invalid = #"{"jsonrpc":"2.0","id":2,"method":"_acpmux/unit_cost","params":{"seconds":900,"hourlyUsd":2,"busyPercent":50,"host":"other"}}"#
        #expect(await transport.send(connection: id, frames: [invalid]) == .intentInvalid)
        #expect(server.peers.first?.frames.filter { $0.contains("_acpmux/unit_cost") }.count == 1)
    }
}
