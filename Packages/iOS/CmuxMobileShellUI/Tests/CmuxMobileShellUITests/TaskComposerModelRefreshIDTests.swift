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

    @Test func settledConnectionMatchesPhysicalMacAndOptionalInstance() {
        let nightly = TaskComposerModelConnectionSnapshot(
            macDeviceID: "selected-mac",
            instanceTag: "nightly"
        )

        #expect(nightly.matchesSelectedMac(
            macDeviceID: "selected-mac",
            instanceTag: "nightly"
        ))
        #expect(nightly.matchesSelectedMac(
            macDeviceID: "selected-mac",
            instanceTag: nil
        ))
        #expect(!nightly.matchesSelectedMac(
            macDeviceID: "selected-mac",
            instanceTag: "stable"
        ))
        #expect(!nightly.matchesSelectedMac(
            macDeviceID: "other-mac",
            instanceTag: nil
        ))
    }
}
#endif
