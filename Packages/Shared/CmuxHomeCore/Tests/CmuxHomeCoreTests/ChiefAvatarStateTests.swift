import CmuxAgentQuestion
import Foundation
import Testing
@testable import CmuxHomeCore

/// What a Chief's avatar in the list reads from its row (relayed by Chief, 2026-11-03: "per-state
/// animations like the Codex status dot: thinking, tool running, waiting on you, done"): whether its
/// running turn is in a tool, and whether it asked the person something still open.
@MainActor @Suite struct ChiefAvatarStateTests {
    let me = ParticipantID("user_me")
    let chief = ParticipantID("agent_chief")
    let conv = ConversationID("conv_a")

    private func activity(_ store: HomeStore, _ line: String) {
        store.handle(.live(.snapshot(conversation: conv, runs: [
            HomeLiveRunSnapshot(author: chief, run: "run_1", steps: [],
                                activity: HomeLiveActivity(line: line, since: Date(timeIntervalSince1970: 0))),
        ])))
    }

    @Test func aRunMovesBetweenTheModelAndATool() {
        let store = HomeStore(source: MockHomeSource(options: .immediate))
        store.handle(.connection(.online))
        activity(store, "Thinking")
        #expect(!store.toolRuns.contains(conv), "the model works: thinking")
        activity(store, "Running swift test")
        #expect(store.toolRuns.contains(conv), "a tool call's line: the tool look")
        activity(store, "Writing the reply")
        #expect(!store.toolRuns.contains(conv))
        activity(store, "Editing src/app.ts")
        store.handle(.live(.snapshot(conversation: conv, runs: [])))
        #expect(!store.toolRuns.contains(conv), "the run ended: no tool")
    }

    @Test func modelLinesAreNotTools() {
        for line in HomeLiveActivity.modelLines {
            #expect(!HomeLiveActivity(line: line, since: .distantPast).isTool)
        }
        #expect(HomeLiveActivity(line: "Reading README.md", since: .distantPast).isTool)
    }

    private func row(_ parts: [MessagePart], author: ParticipantID) -> InboxRow {
        var summary = ConversationSummary(id: conv, participants: [], createdAt: .distantPast, updatedAt: .distantPast)
        summary.lastMessage = Message(id: MessageID("msg_1"), conversation: conv, seq: 1, clientMessageID: IdempotencyKey("k1"),
                                      author: author, parts: parts, createdAt: .distantPast)
        return InboxRow(summary: summary, kind: .chief, title: "Chief", preview: "", previewAuthor: nil,
                        timestamp: .distantPast, unread: 1, isPinned: false, isSending: false, hasFailedSend: false, isTyping: false)
    }

    @Test func anOpenQuestionOrApprovalWaitsOnThePerson() {
        let pending = AgentQuestion(id: "q1", source: .init(harness: .claude, session: "s1"),
                                    items: [.init(id: "i1", prompt: "Which branch?", options: [])])
        #expect(row([.question(pending)], author: chief).waitsOnPerson(me: me))
        var answered = pending
        answered.state = .answered(AgentQuestionAnswer(selections: [:], respondent: nil, answeredAtMs: nil))
        #expect(!row([.question(answered)], author: chief).waitsOnPerson(me: me), "answered: nothing waits")

        let approval = ApprovalRef(request: "r1", prompt: "Run the migration?", options: ["Yes", "No"])
        #expect(row([.approval(approval)], author: chief).waitsOnPerson(me: me))
        #expect(!row([.approval(ApprovalRef(request: "r1", prompt: "Run?", options: ["Yes"], decided: "Yes"))], author: chief)
            .waitsOnPerson(me: me), "decided: nothing waits")

        #expect(!row([.text("All done.")], author: chief).waitsOnPerson(me: me), "a plain reply is done, not waiting")
        #expect(!row([.approval(approval)], author: me).waitsOnPerson(me: me), "my own message never waits on me")
    }
}
