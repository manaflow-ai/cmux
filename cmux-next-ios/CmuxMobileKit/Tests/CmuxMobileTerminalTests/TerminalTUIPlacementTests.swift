import CoreGraphics
import Testing
@testable import CmuxMobileTerminal

/// User report 2026-11-12 ("the resizing is so wack when j tap the thijg"):
/// a full-screen app at a grid another device set (53×28, letterboxed) slid
/// down with the hiding keyboard behind a black band, then jumped back to the
/// top when the keyboard settled. The host was anchored on the composer with
/// the rows claimed at the last settle, so every keyboard move drew it at a
/// stale anchor first.
@Suite struct TerminalTUIPlacementTests {
    let cell: CGFloat = 16, chromeTop: CGFloat = 62
    /// The composer stack's top with the keyboard down (40 rows) and up (22 rows), plus a part row.
    var keyboardDown: CGFloat { chromeTop + 40 * cell + 5 }
    var keyboardUp: CGFloat { chromeTop + 22 * cell + 5 }

    private func placement(hostRows: Int?, phoneRows: Int, stackTop: CGFloat) -> TerminalTUIPlacement {
        TerminalTUIPlacement(cellHeight: cell, hostRows: hostRows, phoneRows: phoneRows, chromeTop: chromeTop, stackTop: stackTop)
    }

    @Test func anotherDevicesGridKeepsOneAnchorWithTheKeyboardUpAndDown() {
        // Settled up, the keyboard's hide pass (the rows still claimed for
        // the keyboard up), settled down, and the show pass.
        let passes = [
            placement(hostRows: 28, phoneRows: 22, stackTop: keyboardUp),
            placement(hostRows: 28, phoneRows: 22, stackTop: keyboardDown),
            placement(hostRows: 28, phoneRows: 40, stackTop: keyboardDown),
            placement(hostRows: 28, phoneRows: 40, stackTop: keyboardUp),
        ]
        for pass in passes {
            #expect(!pass.ridesComposer)
            #expect(pass.hostTop == chromeTop)
        }
        // On the composer, the hide pass put the grid's top 288 pt down: the black band.
        #expect(keyboardDown - 22 * cell - chromeTop > 280)
    }

    @Test func theKeyboardsPassPlacesTheGridAtItsEndPlacement() {
        func grid(_ pass: TerminalTUIPlacement) -> TerminalHostGridLayout {
            TerminalHostGridLayout(viewportWidth: 390, cell: CGSize(width: 7.8, height: cell), scale: 3,
                                   hostColumns: 53, hostRows: 28, visibleRows: pass.visibleRows)
        }
        // Hiding: the pass already letterboxes the 28 rows under 40, unshifted,
        // as the settled layout will (no second placement after did-hide).
        let hiding = grid(placement(hostRows: 28, phoneRows: 22, stackTop: keyboardDown))
        let down = grid(placement(hostRows: 28, phoneRows: 40, stackTop: keyboardDown))
        #expect(hiding.visibleRows == 40)
        #expect(hiding.letterbox?.top == down.letterbox?.top)
        #expect(hiding.rowShift(keeping: 27, from: 6) == 0)
        #expect(hiding.note(owner: nil) == "53×28 · set by another device")
        // Showing: the pass shifts to keep the cursor row above the composer.
        let showing = grid(placement(hostRows: 28, phoneRows: 40, stackTop: keyboardUp))
        #expect(showing.visibleRows == 22)
        #expect(showing.letterbox == nil)
        #expect(showing.rowShift(keeping: 27, from: 0) == 6)
    }

    @Test func thePhonesOwnGridStillRidesTheComposer() {
        // design/terminal R1-1: pinned to the composer until the one resize at the settle.
        for hostRows in [nil, 40] as [Int?] {
            let down = placement(hostRows: hostRows, phoneRows: 40, stackTop: keyboardDown)
            let showing = placement(hostRows: hostRows, phoneRows: 40, stackTop: keyboardUp)
            #expect(down.ridesComposer)
            #expect(down.visibleRows == 40)
            #expect(down.hostTop == keyboardDown - 40 * cell)
            #expect(showing.hostTop == keyboardUp - 40 * cell)
        }
    }

    @Test func switchingAnchorsWhenTheMacResizesMovesLessThanARow() {
        // Settled with the keyboard down, before and after the Mac takes the phone's 40 rows.
        let before = placement(hostRows: 22, phoneRows: 40, stackTop: keyboardDown)
        let after = placement(hostRows: 40, phoneRows: 40, stackTop: keyboardDown)
        #expect(abs(after.hostTop - before.hostTop) < cell)
    }
}
