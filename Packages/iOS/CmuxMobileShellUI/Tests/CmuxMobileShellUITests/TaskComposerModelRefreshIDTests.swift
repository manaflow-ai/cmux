#if os(iOS)
import CmuxMobileShellModel
import Testing
@testable import CmuxMobileShellUI

@Suite struct TaskComposerModelRefreshIDTests {
    @Test func foregroundConnectionChangeRetriesTheSameRequestOwner() {
        let requestID = TaskComposerModelRefreshID(
            provider: .claude,
            macPairingID: "selected-mac#nightly"
        )
        let beforeSwitch = TaskComposerModelRefreshTrigger(
            requestID: requestID,
            connectedMacPairingID: "other-mac#stable"
        )
        let afterSwitch = TaskComposerModelRefreshTrigger(
            requestID: requestID,
            connectedMacPairingID: "selected-mac#nightly"
        )

        #expect(beforeSwitch != afterSwitch)
        #expect(beforeSwitch.requestID == afterSwitch.requestID)
    }

    @Test func providerOrSelectedMacReplacesTheRequestOwner() {
        let initial = TaskComposerModelRefreshID(
            provider: .claude,
            macPairingID: "selected-mac#nightly"
        )
        let changedProvider = TaskComposerModelRefreshID(
            provider: .codex,
            macPairingID: "selected-mac#nightly"
        )
        let changedMac = TaskComposerModelRefreshID(
            provider: .claude,
            macPairingID: "other-mac#stable"
        )

        #expect(initial != changedProvider)
        #expect(initial != changedMac)
    }
}
#endif
