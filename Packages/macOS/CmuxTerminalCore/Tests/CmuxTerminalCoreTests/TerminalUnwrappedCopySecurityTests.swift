import CmuxTerminalCore
import Foundation
import Testing

@Suite
struct TerminalUnwrappedCopySecurityTests {
    @Test func flagRowCannotExtendRemovalCommand() {
        let text = "rm " + String(repeating: "x", count: 70) + "\n-rf \"$HOME/Documents\""
        #expect(TerminalUnwrappedCopy(terminalColumns: 80).unwrappedText(text) == text)
    }

    @Test func longFlagRowCannotExtendPreviousCommand() {
        let text = "tool " + String(repeating: "x", count: 68) + "\n--flag value"
        #expect(TerminalUnwrappedCopy(terminalColumns: 80).unwrappedText(text) == text)
    }

    @Test func largeParagraphUnwrapsWithinWorkBudget() {
        let row = String(repeating: "word ", count: 15) + "tail"
        let rows = Array(repeating: row, count: 20_000)
        let text = rows.joined(separator: "\n")
        #expect(text.utf8.count < 2 * 1024 * 1024)
        let start = ContinuousClock.now
        let actual = TerminalUnwrappedCopy(terminalColumns: 80).unwrappedText(text)
        let elapsed = start.duration(to: .now)
        #expect(actual == rows.joined(separator: " "))
        #expect(elapsed < .seconds(2), "Unwrapping took \(elapsed)")
    }

    @Test func oversizedSelectionIsCopiedUnchanged() {
        // Multibyte text must be bounded by UTF-8 bytes, not character count.
        let text = "  " + String(repeating: "é", count: 1024 * 1024) + "  \n  tail  \n"
        #expect(TerminalUnwrappedCopy(terminalColumns: 80).unwrappedText(text) == text)
    }
}
