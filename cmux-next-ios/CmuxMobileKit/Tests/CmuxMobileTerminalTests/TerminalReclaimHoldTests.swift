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
        hold.restart()
        #expect(hold.held == [])
        _ = hold.take(.output(TerminalReclaimHold.reset), claims: false, phoneGrid: phone, alternate: false)
        #expect(hold.release() == [.output(TerminalReclaimHold.reset)])
    }
}
