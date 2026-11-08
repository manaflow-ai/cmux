import Foundation
import Testing
@testable import CmuxNextAgentPane

@MainActor
struct AgentPaneCloudCredentialTransferTests {
    private static func request(_ params: [String: Any]) -> AgentPaneRequest {
        AgentPaneRequest(body: ["method": AgentPaneCloudCredentialTransferRequest.method, "params": params])
    }

    @Test func mapsNamedProfilesWithoutAcceptingOtherProviders() {
        typealias Provider = AgentPaneCloudCredentialTransferRequest.Provider
        for id in ["claude", "claude-sr2", "Claude_work", "providers/claude-personal"] {
            #expect(Provider(harnessID: id) == .claude)
            #expect(Provider(harnessID: id) != .codex)
        }
        for id in ["codex", "codex-work", "Codex_personal", "providers/codex-team"] {
            #expect(Provider(harnessID: id) == .codex)
        }
        for id: String? in [nil, "", "opencode", "claudelike", "my-claude", "codex/"] {
            #expect(Provider(harnessID: id) == nil)
        }
    }

    @Test func decodesOnlyAProviderAndExactCloudChatScope() throws {
        let params: [String: Any] = ["provider": "claude", "machineID": "vm-123", "sessionId": "session-1", "retryPromptId": "retry-1"]
        let decoded = Self.request(params)
        let request = try #require(AgentPaneCloudCredentialTransferRequest(params: params))
        #expect(decoded == .cloudCredentialTransfer(request))
        #expect(request.automatic == false)
        #expect(AgentPageOps.methods[AgentPaneCloudCredentialTransferRequest.method] == AgentPaneCloudCredentialTransferRequest.method)
        #expect(String(describing: decoded) == "cloudCredentialTransfer")
        for refused: [String: Any] in [
            ["provider": "opencode", "machineID": "vm-123", "sessionId": "session-1", "retryPromptId": "retry-1"],
            ["provider": "codex", "machineID": "vm-123", "sessionId": "session-1", "retryPromptId": "retry-1", "token": "secret"],
            ["provider": "claude", "machineID": "vm/123", "sessionId": "session-1", "retryPromptId": "retry-1"],
            ["provider": "claude", "machineID": "vm-123", "sessionId": "-option", "retryPromptId": "retry-1"],
        ] { #expect(Self.request(refused) == .unsupported(AgentPaneCloudCredentialTransferRequest.method)) }
        let automatic = params.merging(["automatic": true]) { _, new in new }
        let automaticRequest = try #require(AgentPaneCloudCredentialTransferRequest(params: automatic))
        #expect(automaticRequest.automatic)
        #expect(AgentPaneCloudCredentialTransferRequest(params: params.merging(["automatic": "yes"]) { _, new in new }) == nil)
    }

    @Test func aCloudChatNeedsAClickAndSuccessfulAppTransfer() async throws {
        let model = AgentPaneModel(host: NoHost(), sessionId: "session-1")
        model.remoteChat = true
        let wire = AgentPaneRelayedAllowTests.RemoteWire()
        let connection = try await model.transport.open(.remote(AgentPaneRemoteRoute(machine: "host") { wire }))
        defer { model.transport.close(connection: connection) }
        model.transport.sessions.add("session-1")
        let params: [String: Any] = ["provider": "claude", "machineID": "vm-123", "sessionId": "session-1", "retryPromptId": "retry-1"]
        let request = try #require(AgentPaneCloudCredentialTransferRequest(params: params))
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
        let value = try #require(reply["value"] as? [String: Any])
        #expect(value["transferred"] as? Bool == true)
        let ticket = try #require(value["ticket"] as? String)
        let prompt: [String: Any] = ["sessionId": "session-1", "_meta": ["acpmux": ["promptId": "retry-1"]]]
        #expect(model.transport.gestures.redeem(ticket, connection: connection, method: "session/prompt", params: prompt))
        #expect(!model.transport.gestures.redeem(ticket, connection: connection, method: "session/prompt", params: prompt))
        #expect(ran == 1)
        #expect(!model.transport.gestures.isAvailable)
    }

    @Test func localChatNeverTransfersCredentials() async throws {
        let model = AgentPaneModel(host: NoHost(), sessionId: "session-1")
        model.onCloudCredentialTransfer = { _ in Issue.record("local chat called cloud transfer"); return true }
        model.transport.gestures.record(click: true)
        let request = try #require(AgentPaneCloudCredentialTransferRequest(params: ["provider": "codex", "machineID": "vm-123", "sessionId": "session-1", "retryPromptId": "retry-1"]))
        #expect((await model.respond(to: .cloudCredentialTransfer(request)))["ok"] as? Bool != true)
    }

    @Test(arguments: ["delayed", "expired", "session", "prompt", "connection", "refused", "moved"])
    func recoveryGrantRetainsItsOriginalScopeAndExpiry(_ mode: String) async throws {
        let clock = Clock()
        let transport = AgentPaneTransport(gestures: AgentPaneUserGestures(now: { clock.now }))
        let model = AgentPaneModel(host: NoHost(), sessionId: "session-1", transport: transport)
        model.remoteChat = true
        let wire = AgentPaneRelayedAllowTests.RemoteWire()
        let connection = try await transport.open(.remote(AgentPaneRemoteRoute(machine: "host") { wire }))
        defer { transport.close(connection: connection) }
        transport.sessions.add("session-1")
        model.onCloudCredentialTransfer = { _ in
            clock.now = mode == "expired" ? 601 : 60
            if mode == "moved" { model.adoptSession("session-2") }
            return mode != "refused"
        }
        let request = try #require(AgentPaneCloudCredentialTransferRequest(params: [
            "provider": "claude", "machineID": "vm-123", "sessionId": "session-1", "retryPromptId": "retry-1",
        ]))
        transport.gestures.record(click: true)
        let reply = await model.respond(to: .cloudCredentialTransfer(request))
        let value = try #require(reply["value"] as? [String: Any])
        if mode == "refused" || mode == "moved" {
            #expect(value["ticket"] == nil)
            #expect(transport.gestures.debugState.tickets == 0)
        } else {
            let ticket = try #require(value["ticket"] as? String)
            let params: [String: Any] = ["sessionId": mode == "session" ? "session-2" : "session-1",
                                         "_meta": ["acpmux": ["promptId": mode == "prompt" ? "retry-2" : "retry-1"]]]
            let allowed = transport.gestures.redeem(ticket, connection: mode == "connection" ? connection + 1 : connection,
                                                    method: "session/prompt", params: params)
            #expect(allowed == (mode == "delayed"))
        }
    }

    @MainActor private final class Clock { var now: TimeInterval = 0 }

    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }
}
