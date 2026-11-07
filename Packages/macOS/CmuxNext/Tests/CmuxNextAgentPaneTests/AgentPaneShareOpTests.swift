import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The chat's Share dialog (Leo 2026-11-07: share agent chats Google Docs style): `share.op` decodes
/// only known ops with well-formed fields, and a link or an invite needs the person's click.
@MainActor
struct AgentPaneShareOpTests {
    private func request(_ params: [String: Any]) -> AgentPaneRequest {
        AgentPaneRequest(body: ["method": "share.op", "params": params])
    }

    @Test func theOpsDecodeWithTheirFields() {
        if case .shareOp(.state) = request(["op": "state"]) {} else { Issue.record("state") }
        if case .shareOp(.manage) = request(["op": "manage"]) {} else { Issue.record("manage") }
        if case .shareOp(.link(role: "view")) = request(["op": "link", "role": "view"]) {} else { Issue.record("link view") }
        if case .shareOp(.link(role: "view")) = request(["op": "link"]) {} else { Issue.record("link default") }
        if case .shareOp(.invite(account: "a@b.co", role: "talk")) = request(["op": "invite", "account": " a@b.co ", "role": "talk"]) {} else {
            Issue.record("invite")
        }
        if case .shareOp(.uninvite(account: "@leo")) = request(["op": "uninvite", "account": "@leo"]) {} else { Issue.record("uninvite") }
        if case .shareOp(.revoke(shareId: "s1")) = request(["op": "revoke", "shareId": "s1"]) {} else { Issue.record("revoke") }
    }

    @Test func unknownOpsAndBadFieldsAreRefused() {
        let refused: [[String: Any]] = [
            [:], ["op": "delete"], ["op": 7], ["op": "link", "role": "admin"], ["op": "link", "role": 1],
            ["op": "invite", "account": "a@b.co"], ["op": "invite", "account": "", "role": "view"],
            ["op": "invite", "account": String(repeating: "a", count: 400), "role": "view"],
            ["op": "uninvite"], ["op": "revoke"], ["op": "revoke", "shareId": "  "],
        ]
        for params in refused {
            if case .unsupported("share.op") = request(params) {} else { Issue.record("\(params)") }
        }
        #expect(AgentPageOps.methods["share.op"] == "share.op")
    }

    @Test func aLinkOrAnInviteNeedsTheClick() async {
        let model = AgentPaneModel(host: NoHost())
        var asked: [AgentPaneShareOp] = []
        model.onShareOp = { op in asked.append(op); return .value(["ok": true]) }
        for op in [AgentPaneShareOp.link(role: "view"), .invite(account: "a@b.co", role: "view")] {
            let refused = await model.respond(to: .shareOp(op))
            #expect((refused["error"] as? [String: Any])?["code"] as? String == "gesture_required")
            #expect(refused["ok"] as? Bool == false)
            let done = await model.respond(to: .shareOp(op), userGesture: true)
            #expect(done["ok"] as? Bool == true)
        }
        #expect(asked == [.link(role: "view"), .invite(account: "a@b.co", role: "view")], "no op reached the app without a click")
        for op in [AgentPaneShareOp.state, .uninvite(account: "a@b.co"), .revoke(shareId: "s1"), .manage] {
            #expect(await model.respond(to: .shareOp(op))["ok"] as? Bool == true)
        }
    }

    @Test func theAppsRefusalKeepsItsCodeAndNoHookIsUnsupported() async {
        let model = AgentPaneModel(host: NoHost())
        let none = await model.respond(to: .shareOp(.state))
        #expect((none["error"] as? [String: Any])?["code"] as? String == "unsupported")
        model.onShareOp = { _ in .refused(code: "share.needs_sign_in", message: "Sign in") }
        let refused = await model.respond(to: .shareOp(.state))
        #expect((refused["error"] as? [String: Any])?["code"] as? String == "share.needs_sign_in")
    }

    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }
}
