import CmuxAgentChat
import Testing
@testable import CmuxMobileShellUI

@Suite struct WorkspaceChatSessionRefreshOutcomeTests {
    private func descriptor(
        _ id: String,
        terminalID: String? = "terminal",
        state: ChatAgentState = .idle
    ) -> ChatSessionDescriptor {
        ChatSessionDescriptor(
            id: id,
            agentKind: .claude,
            workspaceID: "workspace",
            terminalID: terminalID,
            state: state
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

    @Test func staleWorkspaceDescriptorForSelectedTerminalRequestsAuthoritativePull() {
        let frame = ChatSessionEventFrame(
            sessionID: "session-1",
            event: .descriptorChanged(ChatSessionDescriptor(
                id: "session-1",
                agentKind: .claude,
                workspaceID: "stale-workspace",
                terminalID: "terminal",
                state: .idle
            ))
        )

        #expect(frame.shouldPullAuthoritativeSnapshotForIgnoredWorkspaceFrame(
            workspaceID: "workspace",
            selectedTerminalID: "terminal",
            cachedChatToggleTerminalID: nil
        ))
    }

    @Test func ignoredDescriptorForOtherTerminalDoesNotPull() {
        let frame = ChatSessionEventFrame(
            sessionID: "session-1",
            event: .descriptorChanged(ChatSessionDescriptor(
                id: "session-1",
                agentKind: .claude,
                workspaceID: "other-workspace",
                terminalID: "other-terminal",
                state: .idle
            ))
        )

        #expect(!frame.shouldPullAuthoritativeSnapshotForIgnoredWorkspaceFrame(
            workspaceID: "workspace",
            selectedTerminalID: "terminal",
            cachedChatToggleTerminalID: nil
        ))
    }

    @Test func removedPinnedAliasMigratesToLiveSessionOnCachedTerminal() {
        let sessions = [
            descriptor("real-session", terminalID: "terminal", state: .idle),
            descriptor("other-session", terminalID: "other-terminal", state: .idle),
        ]

        #expect(sessions.replacementSessionIDForPinnedChat(
            pinnedID: "pending-claude-terminal",
            cachedTerminalID: "terminal"
        ) == "real-session")
    }

    @Test func livePinnedSessionDoesNotMigrate() {
        let sessions = [
            descriptor("pending-claude-terminal", terminalID: "terminal", state: .idle),
            descriptor("real-session", terminalID: "terminal", state: .idle),
        ]

        #expect(sessions.replacementSessionIDForPinnedChat(
            pinnedID: "pending-claude-terminal",
            cachedTerminalID: "terminal"
        ) == nil)
    }
}
