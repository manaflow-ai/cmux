import CMUXMobileCore
import CmuxMobileShellModel
import Testing
@testable import CmuxMobileShellUI

@Suite struct WorkspaceTitleMenuValueTests {
    @Test func labelBranchChangesInvalidateTheMenuValue() {
        let standard = menuValue(
            labelToken: .standard(title: "Workspace", subtitle: "Terminal", connectionStatus: .connected)
        )
        let browser = menuValue(
            labelToken: .standard(title: "Workspace", subtitle: "GitHub - cmux", connectionStatus: .connected)
        )
        #expect(menuValue(labelToken: standard.labelToken) == standard)
        #expect(browser != standard)
    }

    @Test func connectionStatusTransitionsInvalidateTheMenuValue() {
        let connected = menuValue(
            labelToken: .standard(title: "Workspace", subtitle: "Terminal", connectionStatus: .connected)
        )
        let reconnecting = menuValue(
            labelToken: .standard(title: "Workspace", subtitle: "Terminal", connectionStatus: .reconnecting)
        )
        let unavailable = menuValue(
            labelToken: .standard(title: "Workspace", subtitle: "Terminal", connectionStatus: .unavailable)
        )
        #expect(reconnecting != connected)
        #expect(unavailable != connected)
        #expect(unavailable != reconnecting)
    }

    @Test func reconnectCapabilityInvalidatesTheMenuValue() {
        let token = WorkspaceTitleMenuLabelToken.standard(
            title: "Workspace",
            subtitle: "Terminal",
            connectionStatus: .unavailable
        )
        let withReconnect = menuValue(labelToken: token, canReconnect: true)
        let withoutReconnect = menuValue(labelToken: token, canReconnect: false)
        #expect(withReconnect != withoutReconnect)
    }

    @Test func customizationCapabilityInvalidatesTheMenuValue() {
        let available = menuValue(
            labelToken: .standard(title: "Workspace", subtitle: "Terminal", connectionStatus: .connected),
            canCustomizeWorkspace: true
        )
        let unavailable = menuValue(
            labelToken: available.labelToken,
            canCustomizeWorkspace: false
        )

        #expect(available != unavailable)
    }

    private func menuValue(
        labelToken: WorkspaceTitleMenuLabelToken,
        canCustomizeWorkspace: Bool = true,
        canReconnect: Bool = false
    ) -> WorkspaceTitleMenuValue {
        WorkspaceTitleMenuValue(
            contentWidth: 390,
            hasBackButton: true,
            backButtonUnreadCount: 0,
            hasTrailingCluster: true,
            measuredTrailingItemsWidth: 0,
            measuredTrailingItemCount: 0,
            trailingItemCount: 0,
            hadTrailingCollapse: false,
            isEnabled: true,
            workspaceName: "Workspace",
            hasUnread: false,
            canCustomizeWorkspace: canCustomizeWorkspace,
            canRenameWorkspace: true,
            canToggleReadState: true,
            canCloseWorkspace: true,
            canReconnect: canReconnect,
            labelToken: labelToken,
            terminalTheme: .monokai
        )
    }
}
