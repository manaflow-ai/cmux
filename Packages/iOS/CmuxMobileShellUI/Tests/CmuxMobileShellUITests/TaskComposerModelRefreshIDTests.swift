#if os(iOS)
import CmuxMobileShellModel
import Testing
@testable import CmuxMobileShellUI

@Suite struct TaskComposerModelRefreshIDTests {
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
