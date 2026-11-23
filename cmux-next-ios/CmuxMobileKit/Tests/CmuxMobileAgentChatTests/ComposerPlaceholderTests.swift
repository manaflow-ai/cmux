@testable import CmuxMobileAgentChat
import Testing

/// Issue 51331: the composer read "Reply to Take over https://github.com/manaflow-…", the tab's
/// title that was still the first prompt. It names the chat only by a title the agent or acpmux
/// gave it (`sessionTitle`), else says "Reply…".
struct ComposerPlaceholderTests {
    @Test func titleNamesTheReply() {
        #expect(AgentChatStore.replyPlaceholder(sessionTitle: "46908: Attention ring timing") == "Reply to 46908: Attention ring timing")
    }

    @Test func noTitleIsPlainReply() {
        #expect(AgentChatStore.replyPlaceholder(sessionTitle: nil) == "Reply…")
        #expect(AgentChatStore.replyPlaceholder(sessionTitle: "") == "Reply…")
    }

    @Test func pillSymbolPerMode() {
        #expect(ACPMode.pillSymbol("bypassPermissions") == "exclamationmark.shield")
        #expect(ACPMode.pillSymbol("agent-full-access") == "exclamationmark.shield")
        #expect(ACPMode.pillSymbol("plan") == "list.bullet.clipboard")
        #expect(ACPMode.pillSymbol("acceptEdits") == "pencil")
        #expect(ACPMode.pillSymbol("custom") == "slider.horizontal.3")
    }
}
