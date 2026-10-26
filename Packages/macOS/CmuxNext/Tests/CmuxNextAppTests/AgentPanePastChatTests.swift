@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import Foundation
import Testing
import CmuxNextWakeups

/// Open Chat on a chat that cannot resume here (cx-khns1): its folder is gone, or acpmux plans a
/// terminal or a read-only transcript. The fresh chat that opens names the chat, and its page's
/// handshake carries the chat's past turns, read through the daemon, until it has a session.
@MainActor @Suite(.serialized)
struct AgentPanePastChatTests {
    private struct Host: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { .mock }
    }

    @MainActor private final class Asked {
        var keys: [String] = []
    }

    private static let key = "codex:0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b"
    private static let subject = ChatOpenSubject(title: "Fix the build", harness: "codex", sessionID: nil, cwd: "/tmp", key: key)

    private static func seed(_ route: ChatOpenRoute) -> AgentPaneSeed? {
        guard case .newWorkspace(_, _, let seed, _, _) = route else { return nil }
        return seed
    }

    /// A terminal or read-only plan opens a fresh chat that shows the chat's past. An adopted chat
    /// names it too: acpmux replays its past only after the folder's trust question, and until
    /// then the reopened chat looked empty (new-user friction run, 2026-10-11).
    @Test func freshChatsForAChatNameIt() throws {
        let terminal = try #require(AcpmuxChatOpenPlan(result: ["kind": "terminal", "cwd": "/tmp", "terminal": ["argv": ["pi", "--resume", "x"]]]))
        let readOnly = try #require(AcpmuxChatOpenPlan(result: ["kind": "readOnly", "readOnly": ["path": "/tmp/x.jsonl"]]))
        let adopt = try #require(AcpmuxChatOpenPlan(result: [
            "kind": "adopt", "cwd": "/tmp", "adopt": ["harness": "codex", "agentSessionId": "x"], "sessionNew": ["cwd": "/tmp"],
        ]))
        #expect(Self.seed(ChatOpenRoute.route(terminal, chat: Self.subject, openTab: { _ in nil }))?.pastChat == Self.key)
        #expect(Self.seed(ChatOpenRoute.route(readOnly, chat: Self.subject, openTab: { _ in nil }))?.pastChat == Self.key)
        #expect(Self.seed(ChatOpenRoute.route(adopt, chat: Self.subject, openTab: { _ in nil }))?.pastChat == Self.key)
    }

    /// The page's handshake carries the past turns of the seed's chat, on every reload while the
    /// chat has no session; a chat with a session reads none.
    @Test func theHandshakeCarriesThePastUntilTheChatHasASession() async throws {
        let asked = Asked()
        AgentPanePastTurn.reader = { chat in
            asked.keys.append(chat)
            return [AgentPanePastTurn(prompt: "Fix the build", answer: "Fixed: a missing import.", promptAt: 1, answerAt: 2)]
        }
        defer { AgentPanePastTurn.reader = nil }
        let model = AgentPaneModel(runner: BackgroundWork(label: "test.agent-pane"), host: Host(), seed: AgentPaneSeedSource(AgentPaneSeed(cwd: "/tmp", pastChat: Self.key)))
        for _ in 0..<2 {
            let reply = await model.respond(to: AgentPaneRequest(body: ["method": "ready"]))
            let result = try #require(reply["value"] as? [String: Any], "\(reply)")
            let turns = try #require(result["pastTurns"] as? [[String: Any]], "\(result)")
            #expect(turns.first?["prompt"] as? String == "Fix the build")
            #expect(turns.first?["answer"] as? String == "Fixed: a missing import.")
        }
        #expect(asked.keys == [Self.key, Self.key])

        let started = AgentPaneModel(runner: BackgroundWork(label: "test.agent-pane"), host: Host(), sessionId: "s1",
                                     seed: AgentPaneSeedSource(AgentPaneSeed(cwd: "/tmp", pastChat: Self.key)))
        let reply = await started.respond(to: AgentPaneRequest(body: ["method": "ready"]))
        #expect((reply["value"] as? [String: Any])?["pastTurns"] == nil)
        #expect(asked.keys.count == 2)
    }
}
