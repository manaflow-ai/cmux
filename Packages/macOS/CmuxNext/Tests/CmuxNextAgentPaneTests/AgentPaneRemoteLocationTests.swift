import Foundation
import Testing
@testable import CmuxNextAgentPane

@MainActor
struct AgentPaneRemoteLocationTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    @Test func reconnectNeedsNamedMachineAndFreshGesture() async {
        let model = AgentPaneModel(host: NoHost())
        var ran: [[String: String]] = []
        model.onRunAction = { id, arguments in
            #expect(id == "remote.reconnect")
            ran.append(arguments)
            return true
        }
        #expect(await model.respond(to: .reconnectMachine("air-blue"))["ok"] as? Bool != true)
        #expect(ran.isEmpty)
        model.transport.gestures.record()
        #expect(await model.respond(to: .runAction("remote.reconnect"))["ok"] as? Bool != true)
        #expect(ran.isEmpty, "a reconnect without its selected target never falls back to the active machine")
        model.transport.gestures.record()
        #expect(await model.respond(to: .reconnectMachine("air-blue"))["ok"] as? Bool == true)
        #expect(ran == [["machine": "air-blue"]])
        #expect(await model.respond(to: .reconnectMachine("other-machine"))["ok"] as? Bool != true)
        #expect(ran.count == 1, "one gesture cannot retry a second machine")
    }

    @Test func aRefusedReconnectIsReported() async {
        let model = AgentPaneModel(host: NoHost())
        model.onRunAction = { _, _ in false }
        model.transport.gestures.record()
        let reply = await model.respond(to: .reconnectMachine("air-blue"))
        #expect(reply["ok"] as? Bool != true)
        #expect((reply["error"] as? [String: Any])?["code"] as? String == "unavailable")
    }

    @Test func reconnectDecodeRequiresABoundedMachine() {
        if case .reconnectMachine("air-blue") = AgentPaneRequest(body: ["method": "action.run", "params": ["id": "remote.reconnect", "machine": "air-blue"]]) {} else {
            Issue.record("The selected machine was not decoded")
        }
        for machine in ["", String(repeating: "x", count: 257)] {
            if case .unsupported = AgentPaneRequest(body: ["method": "action.run", "params": ["id": "remote.reconnect", "machine": machine]]) {} else {
                Issue.record("An invalid machine was decoded")
            }
        }
        if case .unsupported = AgentPaneRequest(body: ["method": "action.run", "params": ["id": "remote.reconnect"]]) {} else {
            Issue.record("A missing target must never fall back to the active workspace")
        }
    }

    @Test func peerSnapshotIsReadOnlyAndDoesNotExposeURLs() throws {
        #expect(AcpmuxPaneMethods.requests.contains("_acpmux/peers"))
        let shape = try #require(AcpmuxPaneMethods.replyShapes["_acpmux/peers"])
        let value = ["peers": [["name": "studio-mac", "state": "offline", "lastSeen": 5,
                               "error": "removed", "url": "ssh://private"]]]
        let filtered = try #require(AcpmuxPaneMethods.filtered(value, to: shape) as? [String: Any])
        let peer = try #require((filtered["peers"] as? [[String: Any]])?.first)
        #expect(peer["state"] as? String == "offline")
        #expect(peer["error"] as? String == "removed")
        #expect(peer["url"] == nil)
    }
}
