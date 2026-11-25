import CmuxNextActions
import Testing
@testable import CmuxNextAgentPane

/// The chat place controls' `sessions` (review of #51824, F4 and F5): Evacuate This Chat and Retry failed
/// name their chats, never "every chat"; a chat-list row names its chat, which the tab need not show.
@MainActor
struct AgentPanePlaceTargetsTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private func decode(_ params: [String: Any]) -> AgentPaneRequest {
        AgentPaneRequest(body: ["method": "action.run", "params": params])
    }

    @Test func evacuateAndBringBackDecodeTheirChats() {
        #expect(decode(["id": "cloudEvacuate", "sessions": ["a", "b"]]) == .runAction("cloudEvacuate", sessions: ["a", "b"]))
        #expect(decode(["id": "cloudBringBackAll", "sessions": ["a"]]) == .runAction("cloudBringBackAll", sessions: ["a"]))
        #expect(decode(["id": "cloudEvacuate"]) == .runAction("cloudEvacuate"))
    }

    @Test func aRowNamesExactlyOneChat() {
        #expect(decode(["id": "chatPlace.set", "mode": "auto", "sessions": ["c"]]) == .runAction("chatPlace.set", mode: "auto", sessions: ["c"]))
        #expect(decode(["id": "chatPlace.set", "mode": "auto", "sessions": ["c", "d"]]) == .unsupported("action.run"))
        #expect(decode(["id": "chatPlace.set", "mode": "auto", "session": "s", "sessions": ["c"]]) == .unsupported("action.run"))
    }

    @Test func badSessionListsAreRefusedNeverDropped() {
        let bad: [Any] = [[String](), [""], ["a,b"], [String(repeating: "a", count: 257)], "a", [7], Array(repeating: "a", count: 501)]
        for value in bad {
            #expect(decode(["id": "cloudEvacuate", "sessions": value]) == .unsupported("action.run"))
        }
        #expect(decode(["id": "newTab.page", "sessions": ["a"]]) == .unsupported("action.run"))
    }

    @Test func namedChatsReachTheAppAndSkipTheShownChatGuard() async {
        let model = AgentPaneModel(host: NoHost())
        var arguments: [[String: String]] = []
        model.onRunAction = { _, args in arguments.append(args); return .ran }
        model.transport.gestures.record()
        #expect(await model.respond(to: .runAction("cloudEvacuate", sessions: ["a", "b"]))["ok"] as? Bool == true)
        model.transport.gestures.record()
        #expect(await model.respond(to: .runAction("chatPlace.set", mode: "cloud", sessions: ["c"]))["ok"] as? Bool == true)
        #expect(arguments == [["sessions": "a,b"], ["sessions": "c", "mode": "cloud"]])
        // The composer's own `session` still binds to the chat the tab shows.
        model.transport.gestures.record()
        #expect(await model.respond(to: .runAction("chatPlace.set", session: "elsewhere", mode: "cloud"))["ok"] as? Bool != true)
    }
}
