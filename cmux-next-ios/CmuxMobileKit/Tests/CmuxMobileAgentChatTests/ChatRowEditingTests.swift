#if os(iOS)
import Foundation
import Testing
@testable import CmuxMobileAgentChat

@MainActor
@Suite struct ChatRowEditingTests {
    @Test func replacingDraftWaitsForConfirmationAndSendsNothing() {
        let source = PromptResendTests.Recorder()
        let store = AgentChatStore(source: source)
        let surface = AgentChatSurface()
        let turn = AgentTurn(id: "t1", prompt: "original prompt", promptAt: Date())
        surface.text = "unfinished draft"
        let sent = source.sent.count

        #expect(!surface.editAndResend(turn, store: store))
        #expect(surface.text == "unfinished draft")
        #expect(surface.editConfirmation == "original prompt")
        #expect(source.sent.count == sent)

        surface.confirmEditAndResend(store: store)
        #expect(surface.text == "original prompt")
        #expect(surface.editConfirmation == nil)
        #expect(surface.composerFocused)
        #expect(source.sent.count == sent)
    }

    @Test func cancelLeavesDraftAndLaterConfirmationDoesNothing() {
        let source = PromptResendTests.Recorder()
        let store = AgentChatStore(source: source)
        let surface = AgentChatSurface()
        surface.text = "unfinished draft"
        let turn = AgentTurn(id: "t1", prompt: "original prompt", promptAt: Date())
        let sent = source.sent.count
        #expect(!surface.editAndResend(turn, store: store))
        surface.editConfirmation = nil
        surface.confirmEditAndResend(store: store)
        #expect(surface.text == "unfinished draft")
        #expect(!surface.composerFocused)
        #expect(source.sent.count == sent)
    }
}
#endif
