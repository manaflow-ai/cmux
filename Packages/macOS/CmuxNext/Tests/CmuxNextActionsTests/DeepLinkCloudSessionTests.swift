import CmuxNextActions
import Foundation
import Testing

/// Team Cloud session links (cloud multiplayer contract C5): `cmux://cloud/session/<team>/<vm>/<session>`
/// for a chat and `cmux://cloud/workspace/<team>/<vm>/<workspace>` for a workspace, plus the
/// `cloud:<team>/<vm>/<session>` key a script passes. What opening one does comes from the team's
/// record (`team.cloud.session.get`): reveal it here, attach to a teammate's, or refuse.
struct DeepLinkCloudSessionTests {
    private static let team = "team_0123456789abcdefghij"
    private static let vm = "vm_8c2f41aa"

    private func parse(_ text: String) -> DeepLink? {
        DeepLink.parse(URL(string: text)!, scheme: "cmux")
    }

    @Test func aChatLinkParsesAndFormatsBack() throws {
        let text = "cmux://cloud/session/\(Self.team)/\(Self.vm)/s_01HZY.claude:2"
        let link = try #require(parse(text))
        #expect(link.target == .cloudSession(team: Self.team, machine: Self.vm, session: "s_01HZY.claude:2", kind: .chat))
        #expect(link.url(scheme: "cmux")?.absoluteString == text)
    }

    @Test func aWorkspaceLinkParsesAndFormatsBack() throws {
        let text = "cmux://cloud/workspace/\(Self.team)/vm-legacy01/ws_44220fb62e6d"
        let link = try #require(parse(text))
        #expect(link.target == .cloudSession(team: Self.team, machine: "vm-legacy01", session: "ws_44220fb62e6d", kind: .workspace))
        #expect(link.url(scheme: "cmux")?.absoluteString == text)
    }

    @Test(arguments: [
        "cmux://cloud/session/team_0123456789ABCDEFGHIJ/vm_8c2f41aa/s1",   // uppercase team
        "cmux://cloud/session/team_0123456789abcdefghi/vm_8c2f41aa/s1",    // 19 characters
        "cmux://cloud/session/grp_0123456789abcdefghij/vm_8c2f41aa/s1",    // not a team
        "cmux://cloud/session/team_0123456789abcdefghij/box_8c2f41aa/s1",  // not a VM
        "cmux://cloud/session/team_0123456789abcdefghij/vm_/s1",           // empty VM id
        "cmux://cloud/session/team_0123456789abcdefghij/vm_8c2f41aa/-s1",  // id starts with a dash
        "cmux://cloud/session/team_0123456789abcdefghij/vm_8c2f41aa",      // no session
        "cmux://cloud/session/team_0123456789abcdefghij/vm_8c2f41aa/s1/x", // one segment too many
        "cmux://cloud/chat/team_0123456789abcdefghij/vm_8c2f41aa/s1",      // unknown kind
        "cmux://cloud/session/team_0123456789abcdefghij/vm_8c2f41aa/s1#turn-2",
    ])
    func aMalformedCloudLinkIsNotALink(_ text: String) {
        #expect(parse(text) == nil)
    }

    @Test func aSessionIDLongerThan128CharactersIsRefused() {
        let id = String(repeating: "a", count: 129)
        #expect(parse("cmux://cloud/session/\(Self.team)/\(Self.vm)/\(id)") == nil)
        #expect(parse("cmux://cloud/session/\(Self.team)/\(Self.vm)/\(id.dropLast())") != nil)
    }

    @Test func theKeyAndEitherSchemeNameTheSameSession() throws {
        let key = try #require(DeepLink.cloudSession("  cloud:\(Self.team)/\(Self.vm)/s1\n"))
        #expect(key.target == .cloudSession(team: Self.team, machine: Self.vm, session: "s1", kind: .chat))
        let dev = try #require(DeepLink.cloudSession("cmux-dev://cloud/workspace/\(Self.team)/\(Self.vm)/ws_1"))
        #expect(dev.target == .cloudSession(team: Self.team, machine: Self.vm, session: "ws_1", kind: .workspace))
        #expect(DeepLink.cloudSession("cloud:\(Self.team)/\(Self.vm)") == nil)
        #expect(DeepLink.cloudSession("cmux://workspace/ws_44220fb62e6d67c82e50c9faf18eb4c3") == nil)
        #expect(DeepLink.cloudSession("https://example.com/cloud/session/\(Self.team)/\(Self.vm)/s1") == nil)
        #expect(DeepLink.cloudSession("https://cloud/session/\(Self.team)/\(Self.vm)/s1") == nil)
    }

    @Test func theWireKindMapsBothWays() {
        #expect(DeepLink.CloudSessionKind(wireKind: "chat") == .chat)
        #expect(DeepLink.CloudSessionKind(wireKind: "workspace") == .workspace)
        #expect(DeepLink.CloudSessionKind(wireKind: "session") == nil)
        #expect(DeepLink.CloudSessionKind.allCases.map(\.wireKind) == ["chat", "workspace"])
    }

    private static let record: [String: Any] = ["session": ["vm": vm, "session": "s1", "kind": "chat", "title": "Fix login"]]

    @Test func aSessionShownHereIsRevealedAndATeammatesIsAttached() {
        let here = DeepLink.cloudSessionPlan(team: Self.team, reply: Self.record, errorCode: nil, signedIn: true) { kind, vm, id in
            kind == .chat && vm == Self.vm && id == "s1"
        }
        #expect(here == .reveal(kind: .chat, machine: Self.vm, session: "s1"))
        let elsewhere = DeepLink.cloudSessionPlan(team: Self.team, reply: Self.record, errorCode: nil, signedIn: true) { _, _, _ in false }
        #expect(elsewhere == .attach(kind: .chat, team: Self.team, machine: Self.vm, session: "s1"))
    }

    @Test func refusalsAreToldApart() {
        let plan = { (code: String?, signedIn: Bool) in
            DeepLink.cloudSessionPlan(team: Self.team, reply: nil, errorCode: code, signedIn: signedIn) { _, _, _ in true }
        }
        #expect(plan("auth.forbidden", true) == .notMember)
        #expect(plan("team.not_member", true) == .notMember)
        #expect(plan("auth.unauthenticated", true) == .notMember)
        #expect(plan("cloud_session.not_found", true) == .gone)
        #expect(plan(nil, true) == .unreachable)
        #expect(plan("rate_limited", true) == .unreachable)
        #expect(plan(nil, false) == .signedOut)
        // A record whose kind this build does not know is not opened as something else.
        let odd: [String: Any] = ["session": ["vm": Self.vm, "session": "s1", "kind": "board"]]
        #expect(DeepLink.cloudSessionPlan(team: Self.team, reply: odd, errorCode: nil, signedIn: true) { _, _, _ in true } == .gone)
    }
}
