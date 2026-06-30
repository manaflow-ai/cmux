import CmuxAgentChat
import CmuxMobileShellModel
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobileShellCompositeAgentChatCacheTests {
    @Test func chatSessionSnapshotCachePrunesRemovedWorkspaces() {
        let store = MobileShellComposite.preview()
        store.signIn()
        let keptWorkspace = MobileWorkspacePreview(
            id: "kept-workspace",
            name: "Kept",
            terminals: [MobileTerminalPreview(id: "terminal-kept", name: "kept")]
        )
        let removedWorkspace = MobileWorkspacePreview(
            id: "removed-workspace",
            name: "Removed",
            terminals: [MobileTerminalPreview(id: "terminal-removed", name: "removed")]
        )
        let session = ChatSessionDescriptor(
            id: "session-1",
            agentKind: .claude,
            workspaceID: "removed-workspace",
            terminalID: "terminal-removed"
        )

        store.setWorkspacesForTesting([keptWorkspace, removedWorkspace])
        store.rememberChatSessions([session], workspaceID: keptWorkspace.id.rawValue)
        store.rememberChatSessions([session], workspaceID: removedWorkspace.id.rawValue)
        #expect(store.cachedChatSessions(workspaceID: removedWorkspace.id.rawValue).isEmpty == false)

        store.setWorkspacesForTesting([keptWorkspace])

        #expect(store.cachedChatSessions(workspaceID: keptWorkspace.id.rawValue).isEmpty == false)
        #expect(store.cachedChatSessions(workspaceID: removedWorkspace.id.rawValue).isEmpty)
    }
}
