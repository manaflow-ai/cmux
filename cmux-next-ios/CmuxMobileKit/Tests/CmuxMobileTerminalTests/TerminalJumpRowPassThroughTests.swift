#if os(iOS)
import CoreGraphics
import Testing
@testable import CmuxMobileTerminal

/// Leo, 2026-11-23: "theres also these weird dead zones in the jump to bottom
/// in terminal... dont add blur there". The Jump to bottom row is the page's
/// width; only the button's target is the button. A touch elsewhere in the row
/// goes to the terminal under it (`TerminalBottomStack`).
@Suite struct TerminalJumpRowPassThroughTests {
    /// A 402 pt iPhone 17 Pro row, 56 pt tall, with the 202 pt centered target.
    let row = CGRect(x: 0, y: 0, width: 402, height: 56)
    let target = CGRect(x: 100, y: 0, width: 202, height: 56)

    @Test func besideTheTargetGoesToTheTerminal() {
        #expect(TerminalBottomStack.passesThrough(CGPoint(x: 20, y: 28), rowBounds: row, target: target))
        #expect(TerminalBottomStack.passesThrough(CGPoint(x: 380, y: 10), rowBounds: row, target: target))
        #expect(TerminalBottomStack.passesThrough(CGPoint(x: 99, y: 50), rowBounds: row, target: target))
    }

    @Test func inTheTargetIsTheButton() {
        #expect(!TerminalBottomStack.passesThrough(CGPoint(x: 201, y: 28), rowBounds: row, target: target))
        #expect(!TerminalBottomStack.passesThrough(CGPoint(x: 106, y: 6), rowBounds: row, target: target))
    }

    @Test func hiddenTheWholeRowIsTheTerminals() {
        #expect(TerminalBottomStack.passesThrough(CGPoint(x: 201, y: 28), rowBounds: row, target: .null))
    }

    @Test func belowTheRowStaysTheStacks() {
        // The key row and the composer keep their touches.
        #expect(!TerminalBottomStack.passesThrough(CGPoint(x: 20, y: 70), rowBounds: row, target: target))
    }
}
#endif
