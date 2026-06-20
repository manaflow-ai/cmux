import CmuxTerminalCore
import Testing

@Suite("Terminal keyboard copy mode clipboard")
struct TerminalKeyboardCopyModeClipboardPackageTests {
    @Test func rawVisualLineFallbackTrimsTrailingLinePadding() {
        let formatter = TerminalKeyboardCopyModeClipboardFormatter()

        #expect(
            formatter.trimTrailingLinePadding("alpha   \nbeta\t\t\ngamma") ==
                "alpha\nbeta\ngamma"
        )
    }

    @Test func rawVisualLineFallbackPreservesEmptyLinesAndFinalNewline() {
        let formatter = TerminalKeyboardCopyModeClipboardFormatter()

        #expect(
            formatter.trimTrailingLinePadding("alpha  \n\nbeta  \n") ==
                "alpha\n\nbeta\n"
        )
    }
}
