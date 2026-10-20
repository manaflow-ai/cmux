import CmuxTerminalCore
import Testing

@Suite
struct TerminalUnwrappedCopyReviewTests {
    @Test func completeURLFillingTheWidthKeepsItsSpace() {
        let text = "  See https://example.com/a/longer/path\n  documentation for the routine"
        #expect(TerminalUnwrappedCopy(terminalColumns: 40).unwrappedText(text)
            == "See https://example.com/a/longer/path documentation for the routine")
    }

    @Test(arguments: ["# This heading fills the row", "| table row fills the width |", "$ a prompt row fills the row"])
    func headingTableAndPromptRowsDoNotAbsorbTheNextRow(row: String) {
        let text = row + "\nbody text starts here"
        #expect(TerminalUnwrappedCopy(terminalColumns: 32, firstLineStartColumn: 0).unwrappedText(text) == text)
    }

    @Test func agentMarkerBeforeAFenceStillProtectsTheCode() {
        let text = "⏺ ```sh\n  echo hello from the first row\n  echo hello from the next row\n  ```"
        #expect(TerminalUnwrappedCopy(terminalColumns: 32, firstLineStartColumn: 0).unwrappedText(text)
            == "```sh\necho hello from the first row\necho hello from the next row\n```")
    }

    @Test func wrapAfterASentenceEndRejoinsWhenTheNextWordDidNotFit() {
        let text = "  This first sentence ends right here.\n  The next sentence continues on."
        #expect(TerminalUnwrappedCopy(terminalColumns: 40).unwrappedText(text)
            == "This first sentence ends right here. The next sentence continues on.")
    }
}
