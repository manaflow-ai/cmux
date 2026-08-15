import CmuxMobileShellModel
import SwiftUI
import Testing
@testable import CmuxMobileShellUI

@MainActor
@Suite struct WorkspaceListConnectionChromeTests {
    @Test func reconnectingStatusShowsStatusLine() {
        #expect(chrome(connectionStatus: .reconnecting) == .statusLine(.reconnecting))
    }

    @Test func recoveringConnectionShowsReconnectingStatusLine() {
        #expect(chrome(
            isRecoveringConnection: true,
            connectionStatus: .reconnecting
        ) == .statusLine(.reconnecting))
    }

    @Test func unavailableStatusShowsNotConnectedStatusLine() {
        #expect(chrome(connectionStatus: .unavailable) == .statusLine(.notConnected))
    }

    @Test func recoveryFailureShowsNotConnectedStatusLine() {
        #expect(chrome(
            connectionRecoveryFailed: true,
            connectionStatus: .unavailable
        ) == .statusLine(.notConnected))
    }

    /// A live reconnect attempt outranks a stale failure flag: the line shows
    /// progress, not the previous defeat.
    @Test func recoveringOutranksFailureInStatusLine() {
        #expect(chrome(
            connectionRecoveryFailed: true,
            isRecoveringConnection: true,
            connectionStatus: .unavailable
        ) == .statusLine(.reconnecting))
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

    @Test func storeRecoveryWithConnectedStatusShowsStatusLine() {
        #expect(chrome(
            isRecoveringConnection: true,
            connectionStatus: .connected
        ) == .statusLine(.reconnecting))
    }

    @Test func storeRecoveryFailureWithConnectedStatusShowsStatusLine() {
        #expect(chrome(
            connectionRecoveryFailed: true,
            connectionStatus: .connected
        ) == .statusLine(.notConnected))
    }

    @Test func initialConnectionLoadingShowsMacStatusRow() {
        #expect(chrome(
            connectionStatus: .reconnecting,
            isInitialConnectionLoading: true
        ) == .macStatusRow)
    }

    @Test func initialConnectionTimeoutShowsMacStatusRow() {
        #expect(chrome(
            connectionStatus: .reconnecting,
            initialConnectionTimedOut: true
        ) == .macStatusRow)
    }

    @Test func reauthOutranksInitialConnectionRestore() {
        #expect(chrome(
            connectionRequiresReauth: true,
            connectionStatus: .reconnecting,
            isInitialConnectionLoading: true
        ) == .recoveryBanner)
    }

    @Test func missingTailscaleAuthorizationShowsCompactStatusBeforeRestoreChrome() {
        #expect(chrome(
            connectionStatus: .reconnecting,
            tailscalePairingRequired: true,
            isInitialConnectionLoading: true
        ) == .statusLine(.notConnected))
    }

    @Test func reauthOutranksMissingTailscaleAuthorization() {
        #expect(chrome(
            connectionRequiresReauth: true,
            connectionStatus: .unavailable,
            tailscalePairingRequired: true
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

    @Test func noStoreReconnectingStatusShowsStatusLine() {
        #expect(chrome(
            hasStore: false,
            connectionRequiresReauth: true,
            connectionRecoveryFailed: true,
            isRecoveringConnection: true,
            connectionStatus: .reconnecting
        ) == .statusLine(.reconnecting))
    }

    @Test func viewChromeUsesStatusLineWithoutStore() {
        let view = WorkspaceListView(
            workspaces: [],
            selectedWorkspaceID: nil,
            host: "Test Mac",
            connectionStatus: .reconnecting,
            navigationStyle: .push,
            wrapWorkspaceTitles: false,
            selectWorkspace: { _ in },
            createWorkspace: {},
            macSelection: binding(initialValue: .all),
            filterState: WorkspaceListFilterState()
        )

        #expect(view.connectionChrome == .statusLine(.reconnecting))
    }

    @Test func viewChromeUsesMacStatusRowDuringInitialRestore() {
        let view = WorkspaceListView(
            workspaces: [],
            selectedWorkspaceID: nil,
            host: "Test Mac",
            connectionStatus: .reconnecting,
            navigationStyle: .push,
            wrapWorkspaceTitles: false,
            selectWorkspace: { _ in },
            createWorkspace: {},
            macSelection: binding(initialValue: .all),
            isInitialConnectionLoading: true,
            filterState: WorkspaceListFilterState()
        )

        #expect(view.connectionChrome == .macStatusRow)
    }

    @Test
    func macUpdateHintIndicatorShowsOnlyWithoutConnectionChrome() {
        #expect(chrome(connectionStatus: .connected).showsMacUpdateHintIndicator)
        #expect(!chrome(connectionRequiresReauth: true, connectionStatus: .connected).showsMacUpdateHintIndicator)
        #expect(!chrome(isRecoveringConnection: true, connectionStatus: .connected).showsMacUpdateHintIndicator)
        #expect(!chrome(connectionRecoveryFailed: true, connectionStatus: .connected).showsMacUpdateHintIndicator)
        #expect(!chrome(connectionStatus: .unavailable).showsMacUpdateHintIndicator)
        #expect(!chrome(connectionStatus: .reconnecting).showsMacUpdateHintIndicator)
        #expect(!chrome(
            connectionStatus: .connected,
            tailscalePairingRequired: true
        ).showsMacUpdateHintIndicator)
    }

    @Test func statusLineAccessorExposesOnlyStatusLineCases() {
        #expect(chrome(connectionStatus: .reconnecting).statusLine == .reconnecting)
        #expect(chrome(connectionStatus: .unavailable).statusLine == .notConnected)
        #expect(chrome(connectionStatus: .connected).statusLine == nil)
        #expect(chrome(
            connectionRequiresReauth: true,
            connectionStatus: .unavailable
        ).statusLine == nil)
        #expect(chrome(
            connectionStatus: .reconnecting,
            isInitialConnectionLoading: true
        ).statusLine == nil)
        #expect(chrome(
            connectionStatus: .connected,
            tailscalePairingRequired: true
        ).statusLine == .notConnected)
    }

    @Test func workspaceDetailReconnectIsUnavailableDuringReauthentication() {
        var reconnectCount = 0
        let blocked = WorkspaceDetailView.reconnectAction(
            connectionRequiresReauth: true
        ) {
            reconnectCount += 1
        }
        #expect(blocked == nil)

        let available = WorkspaceDetailView.reconnectAction(
            connectionRequiresReauth: false
        ) {
            reconnectCount += 1
        }
        #expect(available != nil)
        available?()
        #expect(reconnectCount == 1)
    }

    private func chrome(
        hasStore: Bool = true,
        connectionRequiresReauth: Bool = false,
        connectionRecoveryFailed: Bool = false,
        isRecoveringConnection: Bool = false,
        connectionStatus: MobileMacConnectionStatus,
        tailscalePairingRequired: Bool = false,
        isInitialConnectionLoading: Bool = false,
        initialConnectionTimedOut: Bool = false
    ) -> WorkspaceListConnectionChrome {
        WorkspaceListConnectionChrome(
            hasStore: hasStore,
            connectionRequiresReauth: connectionRequiresReauth,
            connectionRecoveryFailed: connectionRecoveryFailed,
            isRecoveringConnection: isRecoveringConnection,
            connectionStatus: connectionStatus,
            tailscalePairingRequired: tailscalePairingRequired,
            isInitialConnectionLoading: isInitialConnectionLoading,
            initialConnectionTimedOut: initialConnectionTimedOut
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
