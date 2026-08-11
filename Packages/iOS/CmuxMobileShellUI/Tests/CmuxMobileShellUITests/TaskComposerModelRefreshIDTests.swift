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

    @Test func failedProbeRepeatsOnceFromTheSettledConnection() {
        let refresh = TaskComposerModelRefreshID(
            provider: .claude,
            macPairingID: "selected-mac#nightly",
            connectedMacPairingID: "other-mac#stable"
        )

        #expect(refresh.shouldRefreshAgain(
            connectedMacPairingID: "selected-mac#nightly",
            source: .backend
        ))
        #expect(!refresh.shouldRefreshAgain(
            connectedMacPairingID: "selected-mac#nightly",
            source: .discovered
        ))
        #expect(!refresh.shouldRefreshAgain(
            connectedMacPairingID: "other-mac#stable",
            source: .backend
        ))
    }
}
#endif
