import Foundation
import Testing
@testable import CmuxMobileTerminal

/// `TerminalReclaimHold`: the pure rules (DaemonTerminalReclaimHoldTests
/// drives them through the session).
@Suite struct TerminalReclaimHoldTests {
    private let phone = TerminalReclaimHold.Grid(columns: 50, rows: 20)

    @Test func aHiddenBuildLogIsNeverHeldPastTheCap() {
        var hold = TerminalReclaimHold()
        #expect(hold.take(.hostGrid(columns: 120, rows: 40), claims: false, phoneGrid: phone, alternate: false).isEmpty)
        let chunk = Data(repeating: 0x41, count: 1 << 20)
        var shown: [TerminalSessionEvent] = []
        for _ in 0..<9 where shown.isEmpty {
            shown = hold.take(.output(chunk), claims: false, phoneGrid: phone, alternate: false)
        }
        #expect(!hold.isHolding)
        #expect(shown.first == .hostGrid(columns: 120, rows: 40), "past the cap, everything held shows in order")
        #expect(shown.count == 10)
    }

    @Test func withoutAMeasuredGridNothingIsHeld() {
        var hold = TerminalReclaimHold()
        let event = TerminalSessionEvent.hostGrid(columns: 120, rows: 40)
        #expect(hold.take(event, claims: false, phoneGrid: nil, alternate: false) == [event])
        #expect(!hold.isHolding)
    }

    @Test func aReattachSupersedesWhatWasHeldAndKeepsHolding() {
        var hold = TerminalReclaimHold()
        _ = hold.take(.hostGrid(columns: 120, rows: 40), claims: false, phoneGrid: phone, alternate: false)
        _ = hold.take(.output(Data("old".utf8)), claims: false, phoneGrid: phone, alternate: false)
        hold.restart(alternate: false)
        #expect(hold.held == [.hostGrid(columns: 120, rows: 40)], "the held grid stays: the replay does not repeat it")
        _ = hold.take(.output(TerminalReclaimHold.reset), claims: false, phoneGrid: phone, alternate: false)
        #expect(hold.release() == [.hostGrid(columns: 120, rows: 40), .output(TerminalReclaimHold.reset)])
    }

    @Test func aReattachKeepsAnAlternateScreenSwitchItWillNotRepeat() {
        var hold = TerminalReclaimHold()
        _ = hold.take(.hostGrid(columns: 120, rows: 40), claims: false, phoneGrid: phone, alternate: false)
        _ = hold.take(.alternateScreen(true), claims: false, phoneGrid: phone, alternate: true)
        hold.restart(alternate: true)
        #expect(hold.release() == [.hostGrid(columns: 120, rows: 40), .alternateScreen(true)])
        #expect(hold.shownAlternate)
    }

    @Test func releasedAtTheMacsGridNowOnlyItsReplayShows() {
        var hold = TerminalReclaimHold()
        _ = hold.take(.hostGrid(columns: 120, rows: 40), claims: false, phoneGrid: phone, alternate: false)
        _ = hold.take(.alternateScreen(true), claims: false, phoneGrid: phone, alternate: true)
        _ = hold.take(.output(Data("wide".utf8)), claims: false, phoneGrid: phone, alternate: true)
        _ = hold.take(.hostGrid(columns: 50, rows: 20), claims: false, phoneGrid: phone, alternate: true)
        _ = hold.take(.output(Data("narrow".utf8)), claims: false, phoneGrid: phone, alternate: true)
        #expect(hold.release(from: phone) == [.alternateScreen(true), .hostGrid(columns: 50, rows: 20),
                                              .output(TerminalReclaimHold.reset), .output(Data("narrow".utf8))])
    }

    /// A reattach while hidden, at the phone's grid: its reset comes before
    /// its grid, and the release still starts the replay from a reset.
    @Test func releasedAfterAReattachAtThePhonesGridStillResets() {
        var hold = TerminalReclaimHold()
        _ = hold.take(.hostGrid(columns: 120, rows: 40), claims: false, phoneGrid: phone, alternate: false)
        hold.restart(alternate: false)
        _ = hold.take(.output(TerminalReclaimHold.reset), claims: false, phoneGrid: phone, alternate: false)
        _ = hold.take(.hostGrid(columns: 50, rows: 20), claims: false, phoneGrid: phone, alternate: false)
        _ = hold.take(.output(Data("replay".utf8)), claims: false, phoneGrid: phone, alternate: false)
        #expect(hold.release(from: phone) == [.hostGrid(columns: 50, rows: 20), .output(TerminalReclaimHold.reset),
                                              .output(Data("replay".utf8))])
    }
}
