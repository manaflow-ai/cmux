import CmuxMobileShellModel
import Testing
@testable import CmuxMobileShellUI

@Suite struct WorkspaceDetailConnectionChromeTests {
    @Test func reconnectingUsesTitleStatusLine() {
        let chrome = WorkspaceDetailConnectionChrome(
            connectionRequiresReauth: false,
            connectionStatus: .reconnecting
        )

        #expect(chrome == .statusLine(.reconnecting))
        #expect(!chrome.allowsManualReconnect)
    }

    @Test func unavailableUsesTitleStatusLineWithManualReconnect() {
        let chrome = WorkspaceDetailConnectionChrome(
            connectionRequiresReauth: false,
            connectionStatus: .unavailable
        )

        #expect(chrome == .statusLine(.notConnected))
        #expect(chrome.allowsManualReconnect)
    }

    @Test func connectedUsesNoConnectionChrome() {
        let chrome = WorkspaceDetailConnectionChrome(
            connectionRequiresReauth: false,
            connectionStatus: .connected
        )

        #expect(chrome == .none)
        #expect(!chrome.allowsManualReconnect)
    }

    @Test(arguments: [
        MobileMacConnectionStatus.connected,
        MobileMacConnectionStatus.reconnecting,
        MobileMacConnectionStatus.unavailable,
    ])
    func reauthKeepsOnlyRecoveryBanner(status: MobileMacConnectionStatus) {
        let chrome = WorkspaceDetailConnectionChrome(
            connectionRequiresReauth: true,
            connectionStatus: status
        )

        #expect(chrome == .recoveryBanner)
        #expect(chrome.statusLine == nil)
        #expect(!chrome.allowsManualReconnect)
    }
}
