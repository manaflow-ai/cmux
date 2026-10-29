import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Agent session avatars (Leo 2026-10-26: "upload their own"): the page's three requests decode only
/// with a short session id, and the model answers through the app's hooks.
@MainActor
struct AgentPaneAgentAvatarTests {
    private func request(_ method: String, _ params: [String: Any]) -> AgentPaneRequest {
        AgentPaneRequest(body: ["method": method, "params": params])
    }

    @Test func theRequestsTakeOnlyAShortSessionId() {
        if case .agentAvatar("s1") = request("agent.avatar", ["sessionId": "s1"]) {} else { Issue.record("agent.avatar") }
        if case .setAgentAvatar("s1") = request("agent.avatar.set", ["sessionId": "s1"]) {} else { Issue.record("agent.avatar.set") }
        if case .removeAgentAvatar("s1") = request("agent.avatar.remove", ["sessionId": "s1"]) {} else { Issue.record("agent.avatar.remove") }
        for params: [String: Any] in [[:], ["sessionId": ""], ["sessionId": String(repeating: "x", count: 300)], ["sessionId": 7]] {
            if case .unsupported = request("agent.avatar", params) {} else { Issue.record("\(params)") }
        }
    }

    @Test func theModelAnswersThroughTheAppsHooks() async {
        let model = AgentPaneModel(host: NoHost())
        #expect((await model.respond(to: .agentAvatar("s1"))["value"] as? [String: Any])?["src"] == nil, "no hook: no avatar")
        var removed: [String] = []
        model.onAgentAvatar = { $0 == "s1" ? "data:image/png;base64,AAAA" : nil }
        model.onSetAgentAvatar = { _ in "data:image/png;base64,BBBB" }
        model.onRemoveAgentAvatar = { removed.append($0) }
        #expect((await model.respond(to: .agentAvatar("s1"))["value"] as? [String: Any])?["src"] as? String == "data:image/png;base64,AAAA")
        #expect((await model.respond(to: .agentAvatar("s2"))["value"] as? [String: Any])?["src"] == nil)
        #expect((await model.respond(to: .setAgentAvatar("s1"))["value"] as? [String: Any])?["src"] as? String == "data:image/png;base64,BBBB")
        _ = await model.respond(to: .removeAgentAvatar("s1"))
        #expect(removed == ["s1"])
    }

    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }
}
