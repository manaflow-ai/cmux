import CmuxConversationCore
import CmuxMobileShell
import Foundation
import Testing

@testable import CmuxMobileShellUI

@Suite
struct ChiefConversationBackendTests {
    @Test
    func workMessageRendersTitleStatusAndPreviewAlongsideLegacyText() {
        let message = MobileChiefMessage(
            id: "work-message",
            seq: 1,
            authorID: "agent_chief",
            author: "Chief",
            authorKind: "chief",
            text: "Building",
            at: Date(),
            parts: ["work"],
            partPayloads: [MobileChiefPart(
                kind: "work",
                work: MobileChiefWork(
                    session: "session-1",
                    title: "Ship it",
                    status: "running",
                    preview: "Building"
                )
            )]
        )

        #expect(ChiefConversationBackend.displayText(from: message) == "Ship it · running · Building")
    }

    @Test
    func pendingApprovalProjectsToPoll() {
        let message = MobileChiefMessage(
            id: "approval-message",
            seq: 1,
            authorID: "agent_chief",
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
            authorID: "agent_chief",
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

    @Test
    func cancelledChiefQuestionCollapsesToChatReceipt() {
        let question = MobileChiefQuestion(
            id: "question-cancelled",
            source: .init(harness: .chief, session: "chief-main", agentName: "Chief"),
            items: [
                .init(
                    id: "q0",
                    prompt: "Which region?",
                    options: [.init(id: "us", label: "US"), .init(id: "eu", label: "EU")]
                )
            ],
            state: .cancelled
        )
        let message = MobileChiefMessage(
            id: "question-message-cancelled",
            seq: 3,
            authorID: "agent_chief",
            author: "Chief",
            authorKind: "chief",
            text: question.transcriptText,
            at: Date(),
            parts: ["question"],
            partPayloads: [MobileChiefPart(kind: "question", question: question)]
        )

        #expect(ChiefConversationBackend.pendingPoll(from: message) == nil)
        #expect(ChiefConversationBackend.receiptText(from: message) == "Answered in chat")
    }

    @Test
    func multiItemQuestionUsesComposerEntryPoint() {
        let question = MobileChiefQuestion(
            id: "question-2",
            source: .init(harness: .chief, session: "chief-main", agentName: "Chief"),
            items: [
                .init(
                    id: "q0",
                    prompt: "Which region?",
                    options: [.init(id: "us", label: "US")]
                ),
                .init(
                    id: "q1",
                    prompt: "Which tier?",
                    options: [.init(id: "pro", label: "Pro")]
                )
            ]
        )
        let message = MobileChiefMessage(
            id: "question-message-2",
            seq: 3,
            authorID: "agent_chief",
            author: "Chief",
            authorKind: "chief",
            text: question.transcriptText,
            at: Date(),
            parts: ["question"],
            partPayloads: [MobileChiefPart(kind: "question", question: question)]
        )

        let poll = ChiefConversationBackend.pendingPoll(from: message)
        #expect(poll?.question == "Which region?")
        #expect(poll?.options.map(\.id) == [ChiefConversationBackend.questionComposerOptionID])
    }

    @Test
    func multiSelectQuestionUsesComposerEntryPoint() {
        let question = MobileChiefQuestion(
            id: "question-3",
            source: .init(harness: .chief, session: "chief-main", agentName: "Chief"),
            items: [
                .init(
                    id: "q0",
                    prompt: "Which features?",
                    options: [
                        .init(id: "logs", label: "Logs"),
                        .init(id: "metrics", label: "Metrics")
                    ],
                    multiSelect: true
                )
            ]
        )
        let message = MobileChiefMessage(
            id: "question-message-3",
            seq: 4,
            authorID: "agent_chief",
            author: "Chief",
            authorKind: "chief",
            text: question.transcriptText,
            at: Date(),
            parts: ["question"],
            partPayloads: [MobileChiefPart(kind: "question", question: question)]
        )

        let poll = ChiefConversationBackend.pendingPoll(from: message)
        #expect(poll?.question == "Which features?")
        #expect(poll?.options.map(\.id) == [ChiefConversationBackend.questionComposerOptionID])
    }

    @Test
    func singleItemOtherQuestionUsesComposerEntryPoint() {
        let question = MobileChiefQuestion(
            id: "question-other",
            source: .init(harness: .chief, session: "chief-main", agentName: "Chief"),
            items: [.init(
                id: "q0",
                prompt: "What should I call the machine?",
                options: [.init(id: "mac", label: "Mac")],
                allowsOther: true
            )]
        )
        let message = MobileChiefMessage(
            id: "question-message-other",
            seq: 5,
            authorID: "agent_chief",
            author: "Chief",
            authorKind: "chief",
            text: question.transcriptText,
            at: Date(),
            parts: ["question"],
            partPayloads: [MobileChiefPart(kind: "question", question: question)]
        )
        let poll = ChiefConversationBackend.pendingPoll(from: message)
        #expect(poll?.options.map(\.id) == [ChiefConversationBackend.questionComposerOptionID])
    }

    @Test
    func pendingPollSkipsEarlierAnsweredOrUnsupportedCards() {
        let unsupportedQuestion = MobileChiefQuestion(
            id: "question-4",
            source: .init(harness: .chief, session: "chief-main", agentName: "Chief"),
            // An empty question is the unsupported shape. Multi-item asks
            // are supported through the full composer and must remain
            // eligible as the first pending card.
            items: []
        )
        let supportedQuestion = MobileChiefQuestion(
            id: "question-5",
            source: .init(harness: .chief, session: "chief-main", agentName: "Chief"),
            items: [
                .init(
                    id: "q0",
                    prompt: "Use the defaults?",
                    options: [.init(id: "yes", label: "Yes"), .init(id: "no", label: "No")],
                    allowsOther: false
                )
            ]
        )
        let message = MobileChiefMessage(
            id: "question-message-4",
            seq: 5,
            authorID: "agent_chief",
            author: "Chief",
            authorKind: "chief",
            text: "Use the defaults?",
            at: Date(),
            parts: ["approval", "question", "question"],
            partPayloads: [
                MobileChiefPart(
                    kind: "approval",
                    approval: MobileChiefApproval(
                        request: "request-4",
                        prompt: "Run deploy?",
                        options: ["allow", "deny"],
                        decided: "allow"
                    )
                ),
                MobileChiefPart(kind: "question", question: unsupportedQuestion),
                MobileChiefPart(kind: "question", question: supportedQuestion)
            ]
        )

        let poll = ChiefConversationBackend.pendingPoll(from: message)
        #expect(poll?.question == "Use the defaults?")
        #expect(poll?.options.map(\.id) == ["yes", "no"])
    }
}
