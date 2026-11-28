import Testing
@testable import CmuxNextAgentPane

/// A chat's Connect card for a cmux connection: when a tool call answers needs_auth, or the agent asks
/// for a service by name, the page runs `connections.connect` on the person's gesture with the catalog
/// `service` and the chat's link. A malformed service is dropped and runs nothing; a link this build
/// does not open is dropped, so the sign-in returns to Settings > Integrations instead.
@MainActor
struct AgentPaneConnectionsConnectActionTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private func request(_ params: [String: Any]) -> AgentPaneRequest {
        var params = params
        params["id"] = "connections.connect"
        return AgentPaneRequest(body: ["method": "action.run", "params": params])
    }

    @Test func connectRunsOnAGestureWithTheServiceAndTheChatsLink() async {
        let model = AgentPaneModel(host: NoHost())
        model.linkScheme = "cmux-dev-card"
        var ran: [String] = []
        var arguments: [[String: String]] = []
        model.onRunAction = { id, args in ran.append(id); arguments.append(args); return .ran }
        let ask = request(["service": "linear", "returnTo": "cmux-dev-card://session/ses-01"])
        #expect(await model.respond(to: ask)["ok"] as? Bool != true)
        #expect(ran.isEmpty, "no gesture, no sign-in page")
        model.transport.gestures.record()
        #expect(await model.respond(to: ask)["ok"] as? Bool == true)
        #expect(ran == ["connections.connect"])
        #expect(arguments == [["service": "linear", "returnTo": "cmux-dev-card://session/ses-01"]])
    }

    @Test func aCardWithNoUsableServiceRunsNothing() async {
        let model = AgentPaneModel(host: NoHost())
        model.linkScheme = "cmux"
        var ran: [String] = []
        model.onRunAction = { id, _ in ran.append(id); return .ran }
        model.transport.gestures.record()
        #expect(await model.respond(to: request(["service": "--platform=x"]))["ok"] as? Bool != true)
        model.transport.gestures.record()
        #expect(await model.respond(to: request([:]))["ok"] as? Bool != true)
        #expect(ran.isEmpty)
    }

    @Test func aLinkThisBuildDoesNotOpenIsDropped() async {
        let model = AgentPaneModel(host: NoHost())
        model.linkScheme = "cmux"
        var arguments: [[String: String]] = []
        model.onRunAction = { _, args in arguments.append(args); return .ran }
        for link in ["https://evil.example/x", "javascript:alert(1)", "cmux-nightly://session/ses-01", "cmux://auth-callback/x",
                     "cmux://evil.example/session/a", "cmux://session/a?next=https://evil.example"] {
            model.transport.gestures.record()
            #expect(await model.respond(to: request(["service": "sentry", "returnTo": link]))["ok"] as? Bool == true, "\(link)")
        }
        #expect(arguments.allSatisfy { $0 == ["service": "sentry"] }, "\(arguments)")
    }

    @Test func aMalformedServiceIsDroppedAndOnlyConnectCarriesOne() {
        let bad: [Any] = ["", "-linear", "Linear", "linear server", "linear/x", "../linear", "linear?x=1", "--key-stdin",
                          String(repeating: "a", count: 64), 7]
        for bad in bad {
            #expect(request(["service": bad]) == .runAction("connections.connect"), "\(bad)")
        }
        #expect(request(["service": "google-drive"]) == .runAction("connections.connect", service: "google-drive"))
        #expect(request(["service": String(repeating: "a", count: 63)]) == .runAction("connections.connect", service: String(repeating: "a", count: 63)))
        #expect(request(["service": "exa", "returnTo": "cmux://session/s"]) == .runAction("connections.connect", returnTo: "cmux://session/s", service: "exa"))
        #expect(request(["service": "exa", "returnTo": String(repeating: "a", count: 513)]) == .runAction("connections.connect", service: "exa"))
        #expect(AgentPaneRequest(body: ["method": "action.run", "params": ["id": "accounts.githubConnect", "service": "linear"]])
            == .runAction("accounts.githubConnect"))
        #expect(AgentPaneRequest(body: ["method": "action.run", "params": ["id": "connections.connect", "service": "linear", "repo": "acme/web", "org": "acme"]])
            == .runAction("connections.connect", service: "linear"))
    }
}
