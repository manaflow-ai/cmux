#if os(iOS)
import CmuxMobileShellModel
import Testing
@testable import CmuxMobileShellUI

@Suite struct TaskComposerModelRefreshIDTests {
    @Test func providerOrSelectedMacReplacesTheRequestOwner() {
        let initial = TaskComposerModelRefreshID(
            provider: .claude,
            macPairingID: "selected-mac#nightly",
            connectionIdentity: nil,
            connectionState: .disconnected
        )
        let changedProvider = TaskComposerModelRefreshID(
            provider: .codex,
            macPairingID: "selected-mac#nightly",
            connectionIdentity: nil,
            connectionState: .disconnected
        )
        let changedMac = TaskComposerModelRefreshID(
            provider: .claude,
            macPairingID: "other-mac#stable",
            connectionIdentity: nil,
            connectionState: .disconnected
        )

        #expect(initial != changedProvider)
        #expect(initial != changedMac)
    }

    @Test func connectionAvailabilityOrReplacementReplacesTheRequestOwner() {
        let firstConnection = "connection-1"
        let unavailable = TaskComposerModelRefreshID(
            provider: .claude,
            macPairingID: "selected-mac#nightly",
            connectionIdentity: nil,
            connectionState: .disconnected
        )
        let available = TaskComposerModelRefreshID(
            provider: .claude,
            macPairingID: "selected-mac#nightly",
            connectionIdentity: firstConnection,
            connectionState: .connected
        )
        let unchanged = TaskComposerModelRefreshID(
            provider: .claude,
            macPairingID: "selected-mac#nightly",
            connectionIdentity: firstConnection,
            connectionState: .connected
        )
        let replacement = TaskComposerModelRefreshID(
            provider: .claude,
            macPairingID: "selected-mac#nightly",
            connectionIdentity: "connection-2",
            connectionState: .connected
        )

        #expect(unavailable != available)
        #expect(available == unchanged)
        #expect(available != replacement)
    }

    @Test func connectionStateChangeReplacesTheRequestOwner() {
        let disconnected = TaskComposerModelRefreshID(
            provider: .claude,
            macPairingID: "selected-mac#nightly",
            connectionIdentity: "connection-1",
            connectionState: .disconnected
        )
        let connected = TaskComposerModelRefreshID(
            provider: .claude,
            macPairingID: "selected-mac#nightly",
            connectionIdentity: "connection-1",
            connectionState: .connected
        )

        #expect(disconnected != connected)
    }

}
#endif
