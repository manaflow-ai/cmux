import Foundation
import Testing
@testable import CmuxNextAgentPane

@Suite(.serialized)
struct AgentPaneCloudRepositoryTests {
    private actor Capture {
        var method = ""
        var params: [String: any Sendable] = [:]
        var calls = 0
        func record(method: String, params: [String: any Sendable]) { self.method = method; self.params = params; calls += 1 }
        func count() -> Int { calls }
    }

    @Test func validatesCloudRepositoryMethodsAndParameterAllowLists() {
        #expect(AgentPaneCloudRepositoryRequest(method: "cloud.repo.list", params: ["session": "chat-1"]) != nil)
        #expect(AgentPaneCloudRepositoryRequest(method: "cloud.repo.add", params: ["repo": "owner/name", "ref": "main"]) != nil)
        #expect(AgentPaneCloudRepositoryRequest(method: "cloud.repo.sync", params: ["repos": []]) != nil)
        #expect(AgentPaneCloudRepositoryRequest(method: "cloud.repo.wait_github", params: ["timeout_ms": 60_000]) != nil)

        #expect(AgentPaneCloudRepositoryRequest(method: "cloud.repo.list", params: ["unexpected": true]) == nil)
        #expect(AgentPaneCloudRepositoryRequest(method: "cloud.repo.sync", params: ["repos": [], "session": "chat-1"]) == nil)
        #expect(AgentPaneCloudRepositoryRequest(method: "cloud.repo.wait_github", params: ["timeout_ms": 60_001]) == nil)
        #expect(AgentPaneCloudRepositoryRequest(method: "cloud.repo.add", params: ["repo": "", "session": "bad session"]) == nil)
    }

    @Test func remoteActionsOverwritePageSessionWithBoundChat() async throws {
        let request = try #require(AgentPaneCloudRepositoryRequest(method: "cloud.repo.add", params: [
            "repo": "cmux-platform", "session": "attacker-session",
        ]))
        let capture = Capture()
        let reply = await request.reply(remoteChat: true, sessionID: "bound-chat", request: { method, params, _ in
            await capture.record(method: method, params: params)
            return Data(#"{"state":"done","repo":"manaflow-ai/cmux-platform"}"#.utf8)
        })
        #expect(reply["ok"] as? Bool == true)
        #expect(await capture.method == "cloud.repo.add")
        #expect(await capture.params["session"] as? String == "bound-chat")
        #expect(await capture.params["repo"] as? String == "cmux-platform")
    }

    @Test func syncUsesRemoteMachineRouteAndLocalUsesMacRoute() async throws {
        let sync = try #require(AgentPaneCloudRepositoryRequest(method: "cloud.repo.sync", params: ["repos": []]))
        let remoteCapture = Capture()
        let syncReply = await sync.reply(remoteChat: false, sessionID: nil, request: { method, _, _ in
            await remoteCapture.record(method: method, params: [:])
            #expect(method == "cloud.repo.sync")
            return Data(#"{"synced":0}"#.utf8)
        })
        #expect(syncReply["ok"] as? Bool == true)
        #expect(await remoteCapture.count() == 1)

        let local = try #require(AgentPaneCloudRepositoryRequest(method: "cloud.repo.local", params: [:]))
        let localCapture = Capture()
        let localReply = await local.reply(remoteChat: false, sessionID: nil, request: { _, _, _ in
            Issue.record("cloud.repo.local must use the local daemon route")
            return Data("{}".utf8)
        }, localRequest: {
            await localCapture.record(method: "cloud.repo.local", params: [:])
            return Data(#"{"complete":true}"#.utf8)
        })
        #expect(localReply["ok"] as? Bool == true)
        #expect(await localCapture.count() == 1)
    }

    @Test func remoteActionsRequireCloudChatAndBoundSession() async throws {
        let request = try #require(AgentPaneCloudRepositoryRequest(method: "cloud.repo.attached", params: [:]))
        let unavailable = await request.reply(remoteChat: false, sessionID: "chat", request: { _, _, _ in Data("{}".utf8) })
        #expect((unavailable["error"] as? [String: Any])?["code"] as? String == "unavailable")
        let unbound = await request.reply(remoteChat: true, sessionID: nil, request: { _, _, _ in Data("{}".utf8) })
        #expect((unbound["error"] as? [String: Any])?["code"] as? String == "cloud_repo.session_mismatch")
    }
}
