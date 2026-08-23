#if os(iOS)
import Testing

@testable import CmuxMobileShellUI

/// Behavior tests for the connect stage's status projection.
@Suite struct WelcomeConnectionStatusTests {
    @Test func connectionWinsOverEverySearchSignal() {
        let status = WelcomeConnectionStatus(
            isConnected: true,
            macName: "Studio",
            isSearching: true,
            didFinishSearch: false
        )
        #expect(status == .linked(macName: "Studio"))
    }

    @Test func inFlightDiscoveryReportsSearching() {
        let status = WelcomeConnectionStatus(
            isConnected: false,
            macName: nil,
            isSearching: true,
            didFinishSearch: true
        )
        #expect(status == .searching)
    }

    @Test func discoveryNotYetConcludedStillReportsSearching() {
        let status = WelcomeConnectionStatus(
            isConnected: false,
            macName: nil,
            isSearching: false,
            didFinishSearch: false
        )
        #expect(status == .searching)
    }

    @Test func concludedSearchWithoutAMacStalls() {
        let status = WelcomeConnectionStatus(
            isConnected: false,
            macName: nil,
            isSearching: false,
            didFinishSearch: true
        )
        #expect(status == .stalled)
    }

    @Test func blankMacNamesNormalizeToNil() {
        let status = WelcomeConnectionStatus(
            isConnected: true,
            macName: "  \n",
            isSearching: false,
            didFinishSearch: true
        )
        #expect(status == .linked(macName: nil))

        let trimmed = WelcomeConnectionStatus(
            isConnected: true,
            macName: " Studio ",
            isSearching: false,
            didFinishSearch: true
        )
        #expect(trimmed == .linked(macName: "Studio"))
    }
}
#endif
