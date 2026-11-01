import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The environment picker's local row starts a chat on the page's own acpmux, so the handshake names
/// that machine: this Mac for a local connection, the route's machine for a tab attached to another
/// machine's daemon (#28842's review).
@Suite(.serialized)
@MainActor
struct AgentPaneLocalMachineNameTests {
    private actor Host: AgentPaneHostProviding {
        let answer: AgentPaneHandshake
        init(_ answer: AgentPaneHandshake) { self.answer = answer }
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { answer }
    }

    private func localMachineName(answering handshake: AgentPaneHandshake) async throws -> String? {
        let saved = AgentPaneModel.localMachineName
        AgentPaneModel.localMachineName = Task { "office-mac" }
        defer { AgentPaneModel.localMachineName = saved }
        let reply = await AgentPaneHandshakeReply.reply(to: .ready, in: AgentPaneModel(host: Host(handshake)))
        let value = try #require(reply["value"] as? [String: Any])
        return value["localMachineName"] as? String
    }

    @Test func aRemoteRoutesLocalRowIsThatMachine() async throws {
        let wire = AgentPaneRelayedAllowTests.RemoteWire()
        var handshake = AgentPaneHandshake.acpmux(.remote(AgentPaneRemoteRoute(machine: "build-mini") { wire }), sessionId: nil)
        handshake.machineName = "build-mini"
        #expect(try await localMachineName(answering: handshake) == "build-mini")
    }

    @Test func aLocalConnectionsLocalRowIsThisMac() async throws {
        let connection = AcpmuxConnection(url: try #require(URL(string: "ws://127.0.0.1:1/")), dashboardToken: "t", localAppToken: nil)
        var handshake = AgentPaneHandshake.acpmux(connection, sessionId: nil)
        // A chat seeded onto a Cloud machine: machineName names it, the local row stays this Mac.
        handshake.machineName = "kind-aqua-sandpiper"
        #expect(try await localMachineName(answering: handshake) == "office-mac")
    }
}
