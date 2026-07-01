import Foundation
import Testing
@testable import CmuxSettings

@Suite("ClaudeResumePrompt")
struct ClaudeResumePromptTests {
    private let prompt = ClaudeResumePrompt()

    /// Default rendering: pointer (❯) on the recommended first option (summary).
    private let menu = """
    Resuming the full session will consume a substantial portion of your usage limits. We recommend resuming from a summary.
    ❯ 1. Resume from summary (recommended)
      2. Resume full session as-is
      3. Don't ask me again
    """

    @Test func detectsPromptOnlyWhenAllOptionLabelsPresent() {
        #expect(prompt.isVisible(in: menu))
        #expect(!prompt.isVisible(in: "just some normal claude output\nnothing to see"))
        #expect(!prompt.isVisible(in: "Resume from summary mentioned alone"))
        // Two of three labels appearing in prose must NOT count as the menu.
        #expect(!prompt.isVisible(in: "We support Resume from summary and Resume full session as-is here."))
        #expect(!prompt.isVisible(in: """
        Resume from summary
        Resume full session as-is
        Don't ask me again
        """))
        #expect(!prompt.isVisible(in: """
        1. Resume from summary
        unrelated terminal output
        2. Resume full session as-is
        3. Don't ask me again
        """))
    }

    @Test func fullModeMovesDownToSecondOptionThenEnter() {
        #expect(prompt.keystrokes(for: .full, in: menu) == [.down, .enter])
    }

    @Test func summaryModeConfirmsDefaultWithEnter() {
        #expect(prompt.keystrokes(for: .summary, in: menu) == [.enter])
    }

    @Test func askModeNeverActs() {
        #expect(prompt.keystrokes(for: .ask, in: menu) == nil)
    }

    @Test func returnsNilWhenMenuAbsent() {
        #expect(prompt.keystrokes(for: .full, in: "no menu here") == nil)
    }

    /// Order-independence: if Claude lists "full" first with the pointer on it,
    /// full needs only Enter and summary needs one Down.
    @Test func adaptsToReorderedOptions() {
        let reordered = """
        ❯ 1. Resume full session as-is
          2. Resume from summary (recommended)
          3. Don't ask me again
        """
        #expect(prompt.keystrokes(for: .full, in: reordered) == [.enter])
        #expect(prompt.keystrokes(for: .summary, in: reordered) == [.down, .enter])
    }

    /// With no pointer glyph rendered we assume the first option is highlighted.
    @Test func assumesFirstOptionHighlightedWithoutPointer() {
        let noPointer = """
        1. Resume from summary (recommended)
        2. Resume full session as-is
        3. Don't ask me again
        """
        #expect(prompt.keystrokes(for: .full, in: noPointer) == [.down, .enter])
    }

    @Test func usesLatestContiguousMenuBlockWhenTranscriptContainsOldLabels() {
        let screen = """
        Earlier output:
        ❯ 1. Resume from summary (recommended)
          2. Resume full session as-is
          3. Don't ask me again

        Current prompt:
          1. Resume from summary (recommended)
        ❯ 2. Resume full session as-is
          3. Don't ask me again
        """

        #expect(prompt.keystrokes(for: .summary, in: screen) == [.up, .enter])
        #expect(prompt.keystrokes(for: .full, in: screen) == [.enter])
    }

    @Test func ignoresCompleteMenuBlockWhenLaterPromptTextAppears() {
        let stale = """
        ❯ 1. Resume from summary (recommended)
          2. Resume full session as-is
          3. Don't ask me again

        austins-macbook % echo done
        """

        #expect(!prompt.isVisible(in: stale))
        #expect(prompt.keystrokes(for: .full, in: stale) == nil)
    }
}
