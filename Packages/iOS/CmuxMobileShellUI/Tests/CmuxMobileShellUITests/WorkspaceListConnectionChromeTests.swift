import CmuxMobileShellModel
import SwiftUI
import Testing
@testable import CmuxMobileShellUI

@MainActor
@Suite struct WorkspaceListConnectionChromeTests {
    @Test func reconnectingRecoveryShowsMacStatusRow() {
        #expect(chrome(
            isRecoveringConnection: true,
            connectionStatus: .reconnecting
        ) == .macStatusRow)
    }

    @Test func unavailableRecoveryFailureShowsMacStatusRow() {
        #expect(chrome(
            connectionRecoveryFailed: true,
            connectionStatus: .unavailable
        ) == .macStatusRow)
    }

    @Test(arguments: [
        MobileMacConnectionStatus.connected,
        MobileMacConnectionStatus.reconnecting,
        MobileMacConnectionStatus.unavailable,
    ])
    func reauthShowsRecoveryBanner(status: MobileMacConnectionStatus) {
        #expect(chrome(
            connectionRequiresReauth: true,
            connectionRecoveryFailed: true,
            isRecoveringConnection: true,
            connectionStatus: status
        ) == .recoveryBanner)
    }

    @Test func storeRecoveryWithConnectedStatusShowsRecoveryBanner() {
        #expect(chrome(
            isRecoveringConnection: true,
            connectionStatus: .connected
        ) == .recoveryBanner)
    }

    @Test func storeRecoveryFailureWithConnectedStatusShowsRecoveryBanner() {
        #expect(chrome(
            connectionRecoveryFailed: true,
            connectionStatus: .connected
        ) == .recoveryBanner)
    }

    @Test func healthyConnectionShowsNoChrome() {
        #expect(chrome(connectionStatus: .connected) == .none)
    }

    @Test func noStoreConnectedStatusShowsNoChromeEvenWithStoreFlags() {
        #expect(chrome(
            hasStore: false,
            connectionRequiresReauth: true,
            connectionRecoveryFailed: true,
            isRecoveringConnection: true,
            connectionStatus: .connected
        ) == .none)
    }

    @Test func noStoreReconnectingStatusShowsMacStatusRow() {
        #expect(chrome(
            hasStore: false,
            connectionRequiresReauth: true,
            connectionRecoveryFailed: true,
            isRecoveringConnection: true,
            connectionStatus: .reconnecting
        ) == .macStatusRow)
    }

    @Test func viewChromeUsesMacStatusRowWithoutStore() {
        let view = WorkspaceListView(
            workspaces: [],
            selectedWorkspaceID: nil,
            host: "Test Mac",
            connectionStatus: .reconnecting,
            navigationStyle: .push,
            wrapWorkspaceTitles: false,
            selectWorkspace: { _ in },
            createWorkspace: {},
            macSelection: binding(initialValue: .all)
        )

        #expect(view.connectionChrome == .macStatusRow)
    }

    private func chrome(
        hasStore: Bool = true,
        connectionRequiresReauth: Bool = false,
        connectionRecoveryFailed: Bool = false,
        isRecoveringConnection: Bool = false,
        connectionStatus: MobileMacConnectionStatus
    ) -> WorkspaceListConnectionChrome {
        WorkspaceListConnectionChrome.chrome(
            hasStore: hasStore,
            connectionRequiresReauth: connectionRequiresReauth,
            connectionRecoveryFailed: connectionRecoveryFailed,
            isRecoveringConnection: isRecoveringConnection,
            connectionStatus: connectionStatus
        )
    }

    private func binding(initialValue: WorkspaceMacSelection) -> Binding<WorkspaceMacSelection> {
        var value = initialValue
        return Binding(
            get: { value },
            set: { value = $0 }
        )
    }
}
