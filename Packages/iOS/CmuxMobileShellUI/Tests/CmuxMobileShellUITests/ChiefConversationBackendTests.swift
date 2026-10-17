import CmuxConversationCore
import CmuxMobileShell
import Foundation
import Testing

@testable import CmuxMobileShellUI

@Suite
struct ChiefConversationBackendTests {
    @Test
    func pendingApprovalProjectsToPoll() {
        let message = MobileChiefMessage(
            id: "approval-message",
            seq: 1,
            authorID: "chief",
            author: "Chief",
            authorKind: "chief",
            text: "Run deploy?",
            at: Date(),
            parts: ["approval"],
            partPayloads: [MobileChiefPart(
                kind: "approval",
                approval: MobileChiefApproval(
                    request: "request-1", prompt: "Run deploy?", options: ["allow", "deny"]
                )
            )]
        )

        let poll = ChiefConversationBackend.pendingPoll(from: message)
        #expect(poll?.question == "Run deploy?")
        #expect(poll?.options.map(\.id) == ["allow", "deny"])
    }

    @Test
    func answeredQuestionCollapsesToReceipt() {
        let question = MobileChiefQuestion(
            id: "question-1",
            source: .init(harness: .chief, session: "chief-main", agentName: "Chief"),
            items: [
                .init(
                    id: "q0",
                    prompt: "Which region?",
                    options: [.init(id: "us", label: "US")]
                )
            ],
            state: .answered(.init(selections: ["q0": .init(optionIDs: ["us"])]))
        )
        let message = MobileChiefMessage(
            id: "question-message",
            seq: 2,
            authorID: "chief",
            author: "Chief",
            authorKind: "chief",
            text: "Which region?",
            at: Date(),
            parts: ["question"],
            partPayloads: [MobileChiefPart(kind: "question", question: question)]
        )

        #expect(ChiefConversationBackend.pendingPoll(from: message) == nil)
        #expect(ChiefConversationBackend.receiptText(from: message) == "Which region?\n✓ US")
    }
}
