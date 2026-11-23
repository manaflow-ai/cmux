@testable import CmuxMobileAgentChat
import Testing

/// Issue 51331: the composer read "Reply to Take over https://github.com/manaflow-…", the tab's
/// title that was still the first prompt. It names the chat by its title, else says "Reply…".
struct ComposerPlaceholderTests {
    private let prompt = "Take over https://github.com/manaflow-ai/cmux/pull/46908 and land it"

    @Test func sessionTitleWins() {
        #expect(AgentChatStore.replyPlaceholder(sessionTitle: "46908: Attention ring timing", name: prompt, firstPrompt: prompt)
            == "Reply to 46908: Attention ring timing")
    }

    @Test func promptAsTabTitleIsNotTheName() {
        #expect(AgentChatStore.replyPlaceholder(sessionTitle: nil, name: prompt, firstPrompt: prompt) == "Reply…")
        // The Mac cut the prompt with an ellipsis for the tab title.
        #expect(AgentChatStore.replyPlaceholder(sessionTitle: nil, name: "Take over https://github.com/manaflow-…",
                                                firstPrompt: prompt) == "Reply…")
        // A multi-line prompt whose first line is the tab title.
        #expect(AgentChatStore.replyPlaceholder(sessionTitle: nil, name: "Fix the build",
                                                firstPrompt: "Fix the build\nthen run the tests") == "Reply…")
    }

    @Test func namedChatKeepsItsName() {
        #expect(AgentChatStore.replyPlaceholder(sessionTitle: nil, name: "46908: Attention ring timing", firstPrompt: prompt)
            == "Reply to 46908: Attention ring timing")
        #expect(AgentChatStore.replyPlaceholder(sessionTitle: " ", name: "Refactor transport", firstPrompt: nil)
            == "Reply to Refactor transport")
    }

    @Test func untitledOrEmptyIsPlainReply() {
        #expect(AgentChatStore.replyPlaceholder(sessionTitle: nil, name: AgentChatStore.untitledName, firstPrompt: prompt) == "Reply…")
        #expect(AgentChatStore.replyPlaceholder(sessionTitle: "", name: "  ", firstPrompt: nil) == "Reply…")
    }

    @Test func pillSymbolPerMode() {
        #expect(ACPMode.pillSymbol("bypassPermissions") == "exclamationmark.shield")
        #expect(ACPMode.pillSymbol("agent-full-access") == "exclamationmark.shield")
        #expect(ACPMode.pillSymbol("plan") == "list.bullet.clipboard")
        #expect(ACPMode.pillSymbol("acceptEdits") == "pencil")
        #expect(ACPMode.pillSymbol("custom") == "slider.horizontal.3")
    }
}
