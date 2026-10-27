import Foundation
import Testing
@testable import CmuxNextAgentPane

@MainActor
struct AgentPaneCloudCredentialTransferTests {
    private static func request(_ params: [String: Any]) -> AgentPaneRequest {
        AgentPaneRequest(body: ["method": AgentPaneCloudCredentialTransferRequest.method, "params": params])
    }

    @Test func decodesOnlyAProviderAndExactCloudChatScope() {
        let params: [String: Any] = ["provider": "claude", "machineID": "vm-123", "sessionId": "session-1"]
        let decoded = Self.request(params)
        #expect(decoded == .cloudCredentialTransfer(AgentPaneCloudCredentialTransferRequest(params: params)!))
        #expect(AgentPageOps.methods[AgentPaneCloudCredentialTransferRequest.method] == AgentPaneCloudCredentialTransferRequest.method)
        #expect(String(describing: decoded) == "cloudCredentialTransfer")
        for refused: [String: Any] in [
            ["provider": "opencode", "machineID": "vm-123", "sessionId": "session-1"],
            ["provider": "codex", "machineID": "vm-123", "sessionId": "session-1", "token": "secret"],
            ["provider": "claude", "machineID": "vm/123", "sessionId": "session-1"],
            ["provider": "claude", "machineID": "vm-123", "sessionId": "-option"],
        ] { #expect(Self.request(refused) == .unsupported(AgentPaneCloudCredentialTransferRequest.method)) }
    }

    @Test func aCloudChatNeedsAClickAndSuccessfulAppTransfer() async {
        let model = AgentPaneModel(host: NoHost(), sessionId: "session-1")
        model.remoteChat = true
        let params: [String: Any] = ["provider": "claude", "machineID": "vm-123", "sessionId": "session-1"]
        let request = try! #require(AgentPaneCloudCredentialTransferRequest(params: params))
        var ran = 0
        model.onCloudCredentialTransfer = { request in
            #expect(request.machineID == "vm-123")
            ran += 1
            return true
        }
        #expect((await model.respond(to: .cloudCredentialTransfer(request))) ["ok"] as? Bool != true)
        #expect(ran == 0)
        model.transport.gestures.record(click: true)
        let reply = await model.respond(to: .cloudCredentialTransfer(request))
        #expect((reply["value"] as? [String: Bool])?["transferred"] == true)
        #expect(ran == 1)
        #expect(!model.transport.gestures.isAvailable)
    }

    @Test func localChatNeverTransfersCredentials() async {
        let model = AgentPaneModel(host: NoHost(), sessionId: "session-1")
        model.onCloudCredentialTransfer = { _ in Issue.record("local chat called cloud transfer"); return true }
        model.transport.gestures.record(click: true)
        let request = AgentPaneCloudCredentialTransferRequest(params: ["provider": "codex", "machineID": "vm-123", "sessionId": "session-1"])!
        #expect((await model.respond(to: .cloudCredentialTransfer(request)))["ok"] as? Bool != true)
    }

    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }
}
