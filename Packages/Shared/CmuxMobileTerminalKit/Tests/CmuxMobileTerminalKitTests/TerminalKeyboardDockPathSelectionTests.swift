import Testing

@testable import CmuxMobileTerminalKit

@Suite("Keyboard dock path selection")
struct TerminalKeyboardDockPathSelectionTests {
    @Test("legacy is the default on every OS")
    func legacyIsDefault() {
        for os in [18, 26, 27, 28] {
            let selection = TerminalKeyboardDockPathSelection(
                osMajorVersion: os,
                remoteRebuildRevert: false
            )
            #expect(selection.usesLegacyPath)
        }
    }

    @Test("remote revert routes iOS 26 and earlier to the rebuild")
    func remoteRevertSelectsRebuildOnOldOS() {
        for os in [18, 26] {
            let selection = TerminalKeyboardDockPathSelection(
                osMajorVersion: os,
                remoteRebuildRevert: true
            )
            #expect(!selection.usesLegacyPath)
        }
    }

    @Test("no override may route iOS 27+ to the rebuild")
    func iOS27NeverReverts() {
        for os in [27, 28] {
            let remote = TerminalKeyboardDockPathSelection(
                osMajorVersion: os,
                remoteRebuildRevert: true
            )
            #expect(remote.usesLegacyPath)
            let debug = TerminalKeyboardDockPathSelection(
                osMajorVersion: os,
                remoteRebuildRevert: false,
                debugForceRebuild: true
            )
            #expect(debug.usesLegacyPath)
        }
    }

    @Test("debug rebuild force wins over the remote default on iOS 26")
    func debugRebuildForceSelectsRebuild() {
        let selection = TerminalKeyboardDockPathSelection(
            osMajorVersion: 26,
            remoteRebuildRevert: false,
            debugForceRebuild: true
        )
        #expect(!selection.usesLegacyPath)
    }

    @Test("debug legacy force wins over every rebuild input")
    func debugLegacyForceWins() {
        let selection = TerminalKeyboardDockPathSelection(
            osMajorVersion: 26,
            remoteRebuildRevert: true,
            debugForceLegacy: true,
            debugForceRebuild: true
        )
        #expect(selection.usesLegacyPath)
    }
}
