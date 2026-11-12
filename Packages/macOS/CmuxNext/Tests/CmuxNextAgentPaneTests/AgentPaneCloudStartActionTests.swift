import CmuxNextActions
import Testing
@testable import CmuxNextAgentPane

/// New Cloud Chat from a started chat's `/side --on cloud` and `/cd --on cloud` (Leo, 2026-11-06:
/// "Shared chat commands can start in cloud."): the page runs `palette.newCloudChat` on the person's
/// gesture, with its one-time token, which the new tab's seed hands to its page once.
@MainActor
struct AgentPaneCloudStartActionTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private static let token = "0f8e2d1c-5b4a-4c3d-9e8f-7a6b5c4d3e2f"

    @Test func newCloudChatRunsOnAGestureWithItsToken() async {
        let model = AgentPaneModel(host: NoHost())
        var ran: [String] = []
        var arguments: [[String: String]] = []
        model.onRunAction = { id, args in ran.append(id); arguments.append(args); return .ran }
        #expect(await model.respond(to: .runAction("palette.newCloudChat", handoff: Self.token))["ok"] as? Bool != true)
        #expect(ran.isEmpty, "no gesture, no tab")
        model.transport.gestures.record()
        #expect(await model.respond(to: .runAction("palette.newCloudChat", handoff: Self.token))["ok"] as? Bool == true)
        #expect(ran == ["palette.newCloudChat"])
        #expect(arguments == [["handoff": Self.token]])
    }

    /// A token is New Cloud Chat's only, and only a token: anything else is refused, never dropped.
    @Test func aHandoffIsDecodedOnlyForNewCloudChat() {
        #expect(AgentPaneRequest(body: ["method": "action.run", "params": ["id": "palette.newCloudChat", "handoff": Self.token]])
            == .runAction("palette.newCloudChat", handoff: Self.token))
        #expect(AgentPaneRequest(body: ["method": "action.run", "params": ["id": "palette.newCloudChat"]])
            == .runAction("palette.newCloudChat"))
        #expect(AgentPaneRequest(body: ["method": "action.run", "params": ["id": "newCloudMachine", "handoff": Self.token]])
            == .unsupported("action.run"))
        let bad: [Any] = ["short", "has space in it here", String(repeating: "a", count: 65), "../../etc/passwd/../x", 7]
        for value in bad {
            #expect(AgentPaneRequest(body: ["method": "action.run", "params": ["id": "palette.newCloudChat", "handoff": value]])
                == .unsupported("action.run"))
        }
    }

    /// The new tab's page gets the token once, with its Cloud pick: a reload gets neither again.
    @Test func theSeedHandsTheTokenOutOnce() async {
        var seed = AgentPaneSeed(picksCloud: true)
        seed.cloudStartHandoff = Self.token
        let source = AgentPaneSeedSource(seed)
        #expect(!source.holdsOnlyFolder)
        #expect(await source.take()?.cloudStartHandoff == Self.token)
        #expect(await source.take()?.cloudStartHandoff == nil)
    }
}
