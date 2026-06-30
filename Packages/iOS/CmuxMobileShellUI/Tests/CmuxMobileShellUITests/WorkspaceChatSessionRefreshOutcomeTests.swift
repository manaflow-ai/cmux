import CmuxAgentChat
import Testing
@testable import CmuxMobileShellUI

@Suite struct WorkspaceChatSessionRefreshOutcomeTests {
    private func descriptor(_ id: String) -> ChatSessionDescriptor {
        ChatSessionDescriptor(
            id: id,
            agentKind: .claude,
            workspaceID: "workspace",
            terminalID: "terminal",
            state: .idle
        )
    }

    @Test func unavailableRefreshPreservesCachedSessions() {
        let cached = [descriptor("session-1")]

        let result = WorkspaceChatSessionRefreshOutcome.unavailable.applying(to: cached)

        #expect(result == cached)
        #expect(WorkspaceChatSessionRefreshOutcome.unavailable.canInvalidateSelection == false)
    }

    @Test func authoritativeRefreshReplacesCachedSessions() {
        let cached = [descriptor("session-1")]
        let fresh = [descriptor("session-2")]

        let outcome = WorkspaceChatSessionRefreshOutcome.authoritative(fresh)
        let result = outcome.applying(to: cached)

        #expect(result == fresh)
        #expect(outcome.canInvalidateSelection)
    }
}
