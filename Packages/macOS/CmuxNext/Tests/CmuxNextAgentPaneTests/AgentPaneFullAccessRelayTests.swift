import Foundation
import Testing
@testable import CmuxNextAgentPane

/// `sessions.allowFullAccess` at the relay boundary (the page's frames into
/// ``AgentPaneTransport``): off, a switch into a mode that skips approvals is
/// answered `transport.full_access_off` and never reaches acpmux; other modes,
/// and every mode while it is on, go through as before.
@Suite(.serialized)
@MainActor
struct AgentPaneFullAccessRelayTests {
    private func setMode(_ mode: String, allowed: Bool) async throws -> (AgentPaneTransportError?, [String], String?) {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        let inbox = AgentPaneRelayedAllowTests.PageInbox()
        let transport = AgentPaneTransport()
        transport.deliver = { event, done in inbox.deliver(event.frames); done() }
        transport.allowsFullAccess = { allowed }
        transport.sessions.add("s1")
        let id = try await transport.open(AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil))
        #expect(await transport.send(connection: id, frames: [#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#]) == nil)
        transport.gestures.record()
        let frame = #"{"jsonrpc":"2.0","id":5,"method":"session/set_mode","params":{"sessionId":"s1","modeId":"\#(mode)"}}"#
        let error = await transport.send(connection: id, frames: [frame])
        var code: String?
        if error != nil {
            let reply = await inbox.frame(containing: #""id":5"#)
            let object = try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any]
            code = ((object?["error"] as? [String: Any])?["data"] as? [String: Any])?["code"] as? String
        }
        return (error, server.peers.first?.frames ?? [], code)
    }

    @Test func offRefusesAFullAccessModeBeforeAcpmux() async throws {
        let (error, reached, code) = try await setMode("bypassPermissions", allowed: false)
        #expect(error == .fullAccessOff)
        #expect(code == "transport.full_access_off")
        #expect(!reached.contains { $0.contains("set_mode") })
    }

    @Test func offRefusesAFullAccessValueOnAnyConfigOption() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        let inbox = AgentPaneRelayedAllowTests.PageInbox()
        let transport = AgentPaneTransport()
        transport.deliver = { event, done in inbox.deliver(event.frames); done() }
        transport.allowsFullAccess = { false }
        transport.sessions.add("s1")
        let id = try await transport.open(AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil))
        #expect(await transport.send(connection: id, frames: [#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#]) == nil)
        transport.gestures.record()
        let frame = #"{"jsonrpc":"2.0","id":6,"method":"session/set_config_option","params":{"sessionId":"s1","configId":"approvals","value":"bypassPermissions"}}"#
        #expect(await transport.send(connection: id, frames: [frame]) == .fullAccessOff)
    }

    @Test func offKeepsOtherModes() async throws {
        let (error, _, _) = try await setMode("default", allowed: false)
        #expect(error != .fullAccessOff)
    }

    @Test func onLetsAFullAccessModeThrough() async throws {
        let (error, _, _) = try await setMode("bypassPermissions", allowed: true)
        #expect(error != .fullAccessOff)
    }

    @Test(arguments: [("bypassPermissions", true), ("full-access", true), ("yolo", true), ("auto_approve", true),
                      ("default", false), ("plan", false), ("acceptEdits", false), ("read-only", false)])
    func fullAccessModesMatchThePickersWarningRule(mode: String, full: Bool) {
        #expect(AgentPaneModeConfirmation.isFullAccess(mode) == full)
    }
}
