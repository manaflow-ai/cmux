import CmuxAgentQuestion
@testable import CmuxMobileAgentChat
import Foundation
import Testing

private func question(id: String = "q1") -> AgentQuestion {
    AgentQuestion(
        id: id,
        source: AgentQuestion.Source(harness: .claude, session: "s", permission: "p", agentName: "Claude"),
        items: [
            AgentQuestion.Item(id: "a", header: "A", prompt: "One?", options: [
                AgentQuestion.Option(id: "x", label: "X"), AgentQuestion.Option(id: "y", label: "Y"),
            ]),
            AgentQuestion.Item(id: "b", header: "B", prompt: "Any?", options: [
                AgentQuestion.Option(id: "m", label: "M"), AgentQuestion.Option(id: "n", label: "N"), AgentQuestion.Option(id: "o", label: "O"),
            ], multiSelect: true),
            AgentQuestion.Item(id: "c", header: "C", prompt: "Last?", options: [
                AgentQuestion.Option(id: "p", label: "P"), AgentQuestion.Option(id: "q", label: "Q"),
            ]),
        ]
    )
}

@Suite struct QuestionDraftTests {
    @Test func draftRoundTripsThroughTheReducer() {
        let q = question()
        var state = AgentQuestionCardState(question: q)
        _ = state.send(.click(row: 1))      // item a: y, advances to b
        _ = state.send(.click(row: 0))      // b: m
        _ = state.send(.click(row: 2))      // b: o
        let draft = QuestionDraft(state)
        #expect(draft.activeItem == 1)
        #expect(draft.chosen == ["a": ["y"], "b": ["m", "o"]])
        let restored = draft.restore(into: q)
        #expect(restored.activeItem == 1)
        #expect(restored.chosen["a"] == ["y"])
        #expect(restored.chosen["b"] == ["m", "o"])
        #expect(!restored.canSubmit)
    }

    @Test func restoringNeverSubmitsAFullyAnsweredDraft() {
        let draft = QuestionDraft(activeItem: 2, chosen: ["a": ["x"], "b": ["n"], "c": ["q"]])
        let restored = draft.restore(into: question())
        #expect(restored.activeItem == 2)
        #expect(restored.canSubmit)
        #expect(restored.chosen["c"] == ["q"])
    }

    @Test func unknownOptionsAreIgnored() {
        let restored = QuestionDraft(activeItem: 9, chosen: ["a": ["gone"]]).restore(into: question())
        #expect(restored.chosen["a"] == nil)
        #expect(restored.activeItem == 2)
    }

    @MainActor @Test func storePersistsAcrossInstances() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "cmux-mobile-drafts-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let draft = QuestionDraft(activeItem: 1, chosen: ["a": ["y"]])
        QuestionDraftStore(url: url).save(draft, for: "q1")
        #expect(QuestionDraftStore(url: url).draft(for: "q1") == draft)
        let store = QuestionDraftStore(url: url)
        store.clear("q1")
        #expect(QuestionDraftStore(url: url).draft(for: "q1") == nil)
    }
}

@Suite struct ChatTitleTests {
    @Test func agentTitleWins() {
        #expect(AgentChatStore.chatTitle(sessionTitle: "Transport switch", name: "New session", firstPrompt: "hi") == "Transport switch")
    }

    @Test func namedSessionsKeepTheirName() {
        #expect(AgentChatStore.chatTitle(sessionTitle: nil, name: "Refactor transport layer", firstPrompt: "x") == "Refactor transport layer")
    }

    @Test func newSessionTakesTheFirstPrompt() {
        #expect(AgentChatStore.chatTitle(sessionTitle: nil, name: "New session", firstPrompt: "Fix the build") == "Fix the build")
        #expect(AgentChatStore.chatTitle(sessionTitle: nil, name: "New session", firstPrompt: nil) == "New session")
    }

    @Test func longPromptsAreTrimmedTo40AtAWord() {
        let title = AgentChatStore.chatTitle(sessionTitle: nil, name: "New session",
                                             firstPrompt: "Make the transport layer switchable between WebRTC and WireGuard, and add tests")
        #expect(title == "Make the transport layer switchable…")
        #expect(title.count <= 41)
    }

    @Test func sessionInfoUpdateDecodes() throws {
        let json = #"{"sessionUpdate":"session_info_update","title":"Switchable transport"}"#
        let update = try JSONDecoder().decode(ACPSessionUpdate.self, from: Data(json.utf8))
        #expect(update == .sessionInfo(title: "Switchable transport"))
    }
}
