import Testing

@testable import CmuxMobileTerminalKit

@Suite("Keyboard seat selection")
struct TerminalKeyboardSeatSelectionTests {
    @Test("the guide seat is the default on iOS 26 and earlier")
    func guideSeatIsDefaultBeforeIOS27() {
        for os in [18, 26] {
            let selection = TerminalKeyboardSeatSelection(
                osMajorVersion: os,
                remoteRebuildRevert: false
            )
            #expect(selection.usesKeyboardGuideSeat)
            #expect(!selection.seatTrustsOnlyWillFrames)
        }
    }

    @Test("iOS 27+ always seats from notifications and trusts only will frames")
    func iOS27SelectsWillOnlyNotificationSeat() {
        for os in [27, 28] {
            for remote in [false, true] {
                let selection = TerminalKeyboardSeatSelection(
                    osMajorVersion: os,
                    remoteRebuildRevert: remote
                )
                #expect(!selection.usesKeyboardGuideSeat)
                #expect(selection.seatTrustsOnlyWillFrames)
            }
        }
    }

    @Test("remote revert routes iOS 26 and earlier to the full-stream notification seat")
    func remoteRevertSelectsNotificationSeatOnOldOS() {
        for os in [18, 26] {
            let selection = TerminalKeyboardSeatSelection(
                osMajorVersion: os,
                remoteRebuildRevert: true
            )
            #expect(!selection.usesKeyboardGuideSeat)
            #expect(!selection.seatTrustsOnlyWillFrames)
        }
    }

    @Test("debug rebuild force selects the full-stream notification seat on iOS 26")
    func debugRebuildForceSelectsNotificationSeat() {
        let selection = TerminalKeyboardSeatSelection(
            osMajorVersion: 26,
            remoteRebuildRevert: false,
            debugForceRebuild: true
        )
        #expect(!selection.usesKeyboardGuideSeat)
        #expect(!selection.seatTrustsOnlyWillFrames)
    }

    @Test("debug legacy force pins the guide seat over every other input")
    func debugLegacyForceWins() {
        for os in [26, 27] {
            let selection = TerminalKeyboardSeatSelection(
                osMajorVersion: os,
                remoteRebuildRevert: true,
                debugForceLegacy: true,
                debugForceRebuild: true
            )
            #expect(selection.usesKeyboardGuideSeat)
            #expect(!selection.seatTrustsOnlyWillFrames)
        }
    }

    @Test("the iOS 27 seat force selects the will-only notification seat on any OS")
    func iOS27SeatForceWinsEverywhere() {
        for os in [18, 26, 27] {
            let selection = TerminalKeyboardSeatSelection(
                osMajorVersion: os,
                remoteRebuildRevert: false,
                debugForceLegacy: true,
                debugForceIOS27Seat: true
            )
            #expect(!selection.usesKeyboardGuideSeat)
            #expect(selection.seatTrustsOnlyWillFrames)
        }
    }
}
