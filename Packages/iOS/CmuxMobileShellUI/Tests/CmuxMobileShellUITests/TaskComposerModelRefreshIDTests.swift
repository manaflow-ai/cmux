#if os(iOS)
import CmuxMobileShellModel
import Testing
@testable import CmuxMobileShellUI

@Suite struct TaskComposerModelRefreshIDTests {
    @Test func providerOrSelectedMacReplacesTheRequestOwner() {
        let initial = TaskComposerModelRefreshID(
            provider: .claude,
            macPairingID: "selected-mac#nightly",
            connectionIdentity: nil
        )
        let changedProvider = TaskComposerModelRefreshID(
            provider: .codex,
            macPairingID: "selected-mac#nightly",
            connectionIdentity: nil
        )
        let changedMac = TaskComposerModelRefreshID(
            provider: .claude,
            macPairingID: "other-mac#stable",
            connectionIdentity: nil
        )

        #expect(initial != changedProvider)
        #expect(initial != changedMac)
    }

    @Test func connectionAvailabilityOrReplacementReplacesTheRequestOwner() {
        let firstConnection = "connection-1"
        let unavailable = TaskComposerModelRefreshID(
            provider: .claude,
            macPairingID: "selected-mac#nightly",
            connectionIdentity: nil
        )
        let available = TaskComposerModelRefreshID(
            provider: .claude,
            macPairingID: "selected-mac#nightly",
            connectionIdentity: firstConnection
        )
        let unchanged = TaskComposerModelRefreshID(
            provider: .claude,
            macPairingID: "selected-mac#nightly",
            connectionIdentity: firstConnection
        )
        let replacement = TaskComposerModelRefreshID(
            provider: .claude,
            macPairingID: "selected-mac#nightly",
            connectionIdentity: "connection-2"
        )

        #expect(unavailable != available)
        #expect(available == unchanged)
        #expect(available != replacement)
    }

}
#endif
