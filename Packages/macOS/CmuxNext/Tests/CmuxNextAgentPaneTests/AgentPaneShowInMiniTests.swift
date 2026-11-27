import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Show in Mini (Leo 2026-11-07: "we point it not necessarily at the chief, but at a particular
/// coordinator chat"): the chat menu reads which session the floating mini stands for and points it
/// at a chat, or back at the Chief (null). Without the app's hooks the page hides the row.
@MainActor
struct AgentPaneShowInMiniTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private func request(_ method: String, _ params: [String: Any]) -> AgentPaneRequest {
        AgentPaneRequest(body: ["method": method, "params": params])
    }

    @Test func theRequestsDecode() {
        if case .miniSubject = request("agent.mini", [:]) {} else { Issue.record("agent.mini") }
        if case .showInMini("s1") = request("agent.mini.show", ["sessionId": "s1"]) {} else { Issue.record("agent.mini.show s1") }
        if case .showInMini(nil) = request("agent.mini.show", ["sessionId": NSNull()]) {} else { Issue.record("agent.mini.show null") }
        if case .showInMini(nil) = request("agent.mini.show", [:]) {} else { Issue.record("agent.mini.show absent") }
        for params: [String: Any] in [["sessionId": ""], ["sessionId": String(repeating: "x", count: 300)]] {
            if case .unsupported = request("agent.mini.show", params) {} else { Issue.record("\(params)") }
        }
    }

    @Test func theModelAnswersThroughTheAppsHooks() async {
        let model = AgentPaneModel(host: NoHost())
        #expect((await model.respond(to: .miniSubject))["ok"] as? Bool != true, "no hook: the page hides the row")
        var shown: String?? = .none
        var subject: String?
        model.onMiniSubject = { subject }
        model.onShowInMini = { shown = .some($0); subject = $0 }
        #expect(((await model.respond(to: .miniSubject))["value"] as? [String: Any])?["sessionId"] is NSNull, "the Chief: null")
        #expect((await model.respond(to: .showInMini("s1")))["ok"] as? Bool != true, "no click: refused")
        #expect(shown == .none)
        _ = await model.respond(to: .showInMini("s1"), userGesture: true)
        #expect(shown == .some("s1"))
        #expect(((await model.respond(to: .miniSubject))["value"] as? [String: Any])?["sessionId"] as? String == "s1")
        _ = await model.respond(to: .showInMini(nil), userGesture: true)
        #expect(shown == .some(nil))
        // A chat the mini cannot reach (a Chief home's, another machine's tab): no row, no pick.
        model.miniUnreachable = true
        #expect((await model.respond(to: .miniSubject))["ok"] as? Bool != true)
        #expect((await model.respond(to: .showInMini("s1"), userGesture: true))["ok"] as? Bool != true)
        #expect(shown == .some(nil))
    }
}
