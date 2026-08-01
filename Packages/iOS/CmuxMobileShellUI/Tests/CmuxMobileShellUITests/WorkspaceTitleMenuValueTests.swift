import CMUXMobileCore
import CmuxAgentChat
import Testing
@testable import CmuxMobileShellUI

@Suite struct WorkspaceTitleMenuValueTests {
    @Test func labelBranchChangesInvalidateTheMenuValue() {
        let standard = menuValue(
            labelToken: .standard(title: "Workspace", subtitle: "Terminal")
        )
        let browser = menuValue(
            labelToken: .browser(title: "Workspace")
        )
        let chat = menuValue(
            labelToken: .chat(
                descriptor: ChatSessionDescriptor(
                    id: "session-1",
                    agentKind: .codex,
                    title: "Build",
                    state: .idle
                ),
                agentState: .idle,
                isConnected: true,
                titleOverride: "Workspace",
                subtitle: "Terminal"
            )
        )

        #expect(menuValue(labelToken: standard.labelToken) == standard)
        #expect(browser != standard)
        #expect(chat != standard)
        #expect(chat != browser)
    }

    @Test func customizationCapabilityInvalidatesTheMenuValue() {
        let available = menuValue(
            labelToken: .standard(title: "Workspace", subtitle: "Terminal"),
            canCustomizeWorkspace: true
        )
        let unavailable = menuValue(
            labelToken: available.labelToken,
            canCustomizeWorkspace: false
        )

        #expect(available != unavailable)
    }

    @Test func connectionStatusLineInvalidatesTheMenuValue() {
        let connected = menuValue(
            labelToken: .standard(title: "Workspace", subtitle: "Terminal")
        )
        let reconnecting = menuValue(
            labelToken: connected.labelToken,
            connectionStatusLine: .reconnecting
        )

        #expect(connected != reconnecting)
    }

    private func menuValue(
        labelToken: WorkspaceTitleMenuLabelToken,
        canCustomizeWorkspace: Bool = true,
        connectionStatusLine: WorkspaceConnectionStatusLine? = nil
    ) -> WorkspaceTitleMenuValue {
        WorkspaceTitleMenuValue(
            contentWidth: 390,
            hasBackButton: true,
            hasTrailingCluster: true,
            hasChatToggle: true,
            isEnabled: true,
            workspaceName: "Workspace",
            hasUnread: false,
            canCustomizeWorkspace: canCustomizeWorkspace,
            canRenameWorkspace: true,
            canToggleReadState: true,
            canCloseWorkspace: true,
            labelToken: labelToken,
            connectionStatusLine: connectionStatusLine,
            terminalTheme: .monokai
        )
    }
}
