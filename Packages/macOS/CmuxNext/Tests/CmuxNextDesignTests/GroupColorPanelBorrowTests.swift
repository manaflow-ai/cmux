import AppKit
@testable import CmuxNextDesign
import Testing

/// The system color panel is one for the app, and a group editor and Chat Colors both pick with it.
/// Only the latest borrower receives colors: a new borrow ends the previous one (which hears it), and
/// giving it back puts the panel's settings back (cmux#37255 review: Chat Colors took the panel from an
/// open group editor and never handed it back).
@MainActor
@Suite(.serialized)
struct GroupColorPanelBorrowTests {
    /// A color change: setting the shared panel's color sends its action to its target (the lender
    /// while a borrow holds it), as a change in the panel does.
    private func send(_ color: NSColor) {
        NSColorPanel.shared.color = color
    }

    @Test func aNewBorrowEndsThePreviousOneAndOnlyItReceivesColors() {
        let lender = GroupColorPanel()
        var firstPicks = 0, secondPicks = 0, firstEnded = 0
        let first = lender.borrow(start: nil, continuous: true, onPick: { _ in firstPicks += 1 },
                                  onEnd: { firstEnded += 1 })
        send(.red)
        #expect(firstPicks == 1)

        let second = lender.borrow(start: nil, continuous: false, onPick: { _ in secondPicks += 1 }, onEnd: {})
        #expect(firstEnded == 1)
        #expect(!lender.holds(first))
        #expect(lender.holds(second))
        send(.blue)
        #expect(firstPicks == 1)
        #expect(secondPicks == 1)

        // The first borrower giving back late changes nothing for the second.
        lender.giveBack(first)
        send(.green)
        #expect(secondPicks == 2)
        lender.giveBack(second)
    }

    @Test func givingBackRestoresThePanelsSettingsAndStopsColors() {
        let panel = NSColorPanel.shared
        let before = (panel.showsAlpha, panel.isContinuous)
        panel.showsAlpha = true
        panel.isContinuous = false
        defer { (panel.showsAlpha, panel.isContinuous) = before }

        let lender = GroupColorPanel()
        var picks = 0, ended = 0
        let borrow = lender.borrow(start: .red, continuous: true, onPick: { _ in picks += 1 }, onEnd: { ended += 1 })
        #expect(panel.isContinuous)
        #expect(!panel.showsAlpha)
        // Setting the start color is not a pick.
        #expect(picks == 0)

        lender.giveBack(borrow)
        #expect(panel.showsAlpha)
        #expect(!panel.isContinuous)
        #expect(ended == 0)
        send(.blue)
        #expect(picks == 0)
    }
}
