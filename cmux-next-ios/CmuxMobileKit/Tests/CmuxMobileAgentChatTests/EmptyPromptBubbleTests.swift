@testable import CmuxMobileAgentChat
import Foundation
import Testing

/// A turn whose prompt has no text and no attachments draws no user bubble: an empty grey bubble
/// is a placeholder. Leo, 2026-11-24: "holy sh*t this is a huge problem in ios... wer need to
/// chase all these placeholders doen and prevent them".
@Suite struct EmptyPromptBubbleTests {
    final class Recorder: AgentSessionSource {
        let summary = AgentSessionSummary(id: "s", name: "S", harness: "claude", agentName: "Claude", cwd: "~", workspaceTitle: "w", macName: "m")
        func events() -> AsyncStream<AgentSessionEvent> { AsyncStream { _ in } }
        func send(_ intent: AgentClientIntent) {}
    }

    @MainActor private func rows(_ store: AgentChatStore) -> [ChatRow] {
        ChatTranscriptBuilder(diffs: ChatDiffCache()).build(turns: store.turns, pendingPermission: nil, askOpen: false,
                                                           permissionBarHidden: false).flatMap(\.rows)
    }

    private func prompts(_ rows: [ChatRow]) -> [String] {
        rows.compactMap { if case .prompt(let text, _, _, _) = $0.kind { text } else { nil } }
    }

    @MainActor @Test func aTurnWithAnEmptyPromptDrawsNoBubbleButKeepsItsReply() {
        let store = AgentChatStore(source: Recorder())
        store.apply(.userMessage(text: "Fix the grid", promptId: "p-1", turnId: "t-1", attachments: [], at: Date()))
        store.apply(.turnStarted(turnId: "t-1", at: Date()))
        store.apply(.update(.agentMessageChunk(text: "Fixed.", messageId: "m-1")))
        store.apply(.turnResult(turnId: "t-1", status: .completed, errorText: nil, at: Date()))
        for blank in ["", "  \n "] {
            let id = "t-\(blank.count + 2)"
            store.apply(.userMessage(text: blank, promptId: "p-\(id)", turnId: id, attachments: [], at: Date()))
            store.apply(.turnStarted(turnId: id, at: Date()))
            store.apply(.update(.agentMessageChunk(text: "Carrying on \(id).", messageId: "m-\(id)")))
            store.apply(.turnResult(turnId: id, status: .completed, errorText: nil, at: Date()))
        }
        let rows = rows(store)
        #expect(prompts(rows) == ["Fix the grid"], "no empty bubble: \(rows.map(\.id))")
        #expect(rows.contains { $0.id == "u-t-1" })
        #expect(!rows.contains { $0.id == "u-t-2" || $0.id == "u-t-6" })
    }
}
