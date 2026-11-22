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
        if case .shareOp(.state, session: nil) = request(["op": "state"]) {} else { Issue.record("state") }
        if case .shareOp(.manage, session: nil) = request(["op": "manage"]) {} else { Issue.record("manage") }
        if case .shareOp(.link(role: "view"), session: nil) = request(["op": "link", "role": "view"]) {} else { Issue.record("link view") }
        if case .shareOp(.link(role: "view"), session: nil) = request(["op": "link"]) {} else { Issue.record("link default") }
        if case .shareOp(.invite(account: "a@b.co", role: "talk"), session: nil) = request(["op": "invite", "account": " a@b.co ", "role": "talk"]) {} else {
            Issue.record("invite")
        }
        if case .shareOp(.uninvite(account: "@leo"), session: nil) = request(["op": "uninvite", "account": "@leo"]) {} else { Issue.record("uninvite") }
        if case .shareOp(.revoke(shareId: "s1"), session: nil) = request(["op": "revoke", "shareId": "s1"]) {} else { Issue.record("revoke") }
    }

    @Test func unknownOpsAndBadFieldsAreRefused() {
        let refused: [[String: Any]] = [
            [:], ["op": "delete"], ["op": 7], ["op": "link", "role": "admin"], ["op": "link", "role": 1],
            ["op": "invite", "account": "a@b.co"], ["op": "invite", "account": "", "role": "view"],
            ["op": "invite", "account": String(repeating: "a", count: 400), "role": "view"],
            ["op": "uninvite"], ["op": "revoke"], ["op": "revoke", "shareId": "  "],
            ["op": "state", "session": ""], ["op": "state", "session": 7], ["op": "state", "session": String(repeating: "s", count: 300)],
        ]
        for params in refused {
            if case .unsupported("share.op") = request(params) {} else { Issue.record("\(params)") }
        }
        #expect(AgentPageOps.methods["share.op"] == "share.op")
    }

    @Test func aLinkOrAnInviteNeedsTheClick() async {
        let model = AgentPaneModel(host: NoHost())
        var asked: [AgentPaneShareOp] = []
        model.onShareOp = { op, _ in asked.append(op); return .value(["ok": true]) }
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

    /// The dialog names the chat it opened on (`session`): once the tab shows another chat, every
    /// op is refused before the app is asked and before a click is spent.
    @Test func anOpForAChatTheTabNoLongerShowsIsRefused() async {
        if case .shareOp(.state, session: "chat-a") = request(["op": "state", "session": "chat-a"]) {} else { Issue.record("session") }
        let model = AgentPaneModel(host: NoHost())
        var shown = "chat-a"
        var asked: [(AgentPaneShareOp, String?)] = []
        model.onShareOp = { op, session in asked.append((op, session)); return .value([:]) }
        model.header = AgentPaneHeaderHooks(run: { _, _ in }, tabState: { AgentPaneHeaderState() }, showsChat: { $0 == shown })
        #expect(await model.respond(to: .shareOp(.link(role: "view"), session: "chat-a"), userGesture: true)["ok"] as? Bool == true)
        #expect(asked.last?.1 == "chat-a", "the session goes on to the app as the daemon's pin")
        shown = "chat-b"
        model.transport.gestures.record()
        for op in [AgentPaneShareOp.state, .link(role: "view"), .revoke(shareId: "s1")] {
            let refused = await model.respond(to: .shareOp(op, session: "chat-a"), userGesture: true)
            #expect((refused["error"] as? [String: Any])?["code"] as? String == "unavailable")
        }
        #expect(asked.count == 1, "nothing reached the app for the chat the tab no longer shows")
        #expect(model.transport.gestures.consume(), "the refused ops spent no click")
        #expect(await model.respond(to: .shareOp(.state))["ok"] as? Bool == true, "an older page names no session")
    }

    @Test func theAppsRefusalKeepsItsCodeAndNoHookIsUnsupported() async {
        let model = AgentPaneModel(host: NoHost())
        let none = await model.respond(to: .shareOp(.state))
        #expect((none["error"] as? [String: Any])?["code"] as? String == "unsupported")
        model.onShareOp = { _, _ in .refused(code: "share.needs_sign_in", message: "Sign in") }
        let refused = await model.respond(to: .shareOp(.state))
        #expect((refused["error"] as? [String: Any])?["code"] as? String == "share.needs_sign_in")
    }

    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }
}
