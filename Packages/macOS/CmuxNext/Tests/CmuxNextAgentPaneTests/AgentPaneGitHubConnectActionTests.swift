import Testing
@testable import CmuxNextAgentPane

/// A chat's Connect GitHub card (Leo, 2026-11-10: "Just as few hurdles to jump through as
/// possible"): the page runs `accounts.githubConnect` on the person's gesture with the failed call's
/// repository and the chat's link. A malformed repository or a link this build does not open is
/// dropped, never passed on to GitHub's return.
@MainActor
struct AgentPaneGitHubConnectActionTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private func request(_ params: [String: Any]) -> AgentPaneRequest {
        var params = params
        params["id"] = "accounts.githubConnect"
        return AgentPaneRequest(body: ["method": "action.run", "params": params])
    }

    @Test func connectRunsOnAGestureWithTheRepositoryAndTheChatsLink() async {
        let model = AgentPaneModel(host: NoHost())
        model.linkScheme = "cmux-dev-card"
        var ran: [String] = []
        var arguments: [[String: String]] = []
        model.onRunAction = { id, args in ran.append(id); arguments.append(args); return .ran }
        let ask = request(["repo": "acme/web", "returnTo": "cmux-dev-card://session/ses-01"])
        #expect(await model.respond(to: ask)["ok"] as? Bool != true)
        #expect(ran.isEmpty, "no gesture, no GitHub page")
        model.transport.gestures.record()
        #expect(await model.respond(to: ask)["ok"] as? Bool == true)
        #expect(ran == ["accounts.githubConnect"])
        #expect(arguments == [["repo": "acme/web", "returnTo": "cmux-dev-card://session/ses-01"]])
    }

    @Test func aLinkThisBuildDoesNotOpenIsDropped() async {
        let model = AgentPaneModel(host: NoHost())
        model.linkScheme = "cmux"
        var arguments: [[String: String]] = []
        model.onRunAction = { _, args in arguments.append(args); return .ran }
        for link in ["https://evil.example/x", "javascript:alert(1)", "cmux-nightly://session/ses-01", "cmux://auth-callback/x",
                     "cmux://evil.example/session/a", "cmux://session/a?next=https://evil.example"] {
            model.transport.gestures.record()
            #expect(await model.respond(to: request(["repo": "acme/web", "returnTo": link]))["ok"] as? Bool == true, "\(link)")
        }
        #expect(arguments.allSatisfy { $0 == ["repo": "acme/web"] }, "\(arguments)")
    }

    @Test func aMalformedRepositoryIsDroppedAndOnlyConnectCarriesOne() {
        let bad: [Any] = ["acme", "acme/web/extra", "-acme/web", "acme/..", "acme/.", "ac me/web", "acme/web?x=1", String(repeating: "a", count: 40) + "/web", 7]
        for bad in bad {
            #expect(request(["repo": bad]) == .runAction("accounts.githubConnect"), "\(bad)")
        }
        #expect(request(["repo": "acme-co/web.app_2"]) == .runAction("accounts.githubConnect", repo: "acme-co/web.app_2"))
        #expect(AgentPaneRequest(body: ["method": "action.run", "params": ["id": "palette.openCloudPane", "repo": "acme/web", "returnTo": "cmux://session/s"]])
            == .runAction("palette.openCloudPane"))
        #expect(request(["returnTo": String(repeating: "a", count: 513)]) == .runAction("accounts.githubConnect"))
    }
}
