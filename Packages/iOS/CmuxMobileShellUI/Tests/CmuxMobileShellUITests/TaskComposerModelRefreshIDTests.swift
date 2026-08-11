#if os(iOS)
import CmuxMobileShellModel
import Testing
@testable import CmuxMobileShellUI

@Suite struct TaskComposerModelRefreshIDTests {
    @Test func foregroundConnectionChangeDoesNotReplaceTheRequestOwner() {
        let beforeSwitch = TaskComposerModelRefreshID(
            provider: .claude,
            macPairingID: "selected-mac#nightly",
            connectedMacPairingID: "other-mac#stable"
        )
        let afterSwitch = TaskComposerModelRefreshID(
            provider: .claude,
            macPairingID: "selected-mac#nightly",
            connectedMacPairingID: "selected-mac#nightly"
        )

        #expect(beforeSwitch == afterSwitch)
    }
}
#endif
