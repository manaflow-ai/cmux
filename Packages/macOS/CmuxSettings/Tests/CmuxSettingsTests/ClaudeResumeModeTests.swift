import Foundation
import Testing
@testable import CmuxSettings

@Suite("ClaudeResumeMode")
struct ClaudeResumeModeTests {
    @Test func tolerantRawStringParse() {
        #expect(ClaudeResumeMode(rawString: "ask") == .ask)
        #expect(ClaudeResumeMode(rawString: "FULL") == .full)
        #expect(ClaudeResumeMode(rawString: "  full-session ") == .full)
        #expect(ClaudeResumeMode(rawString: "Summary") == .summary)
        #expect(ClaudeResumeMode(rawString: "manual") == .ask)
        #expect(ClaudeResumeMode(rawString: "garbage") == nil)
        #expect(ClaudeResumeMode(rawString: "") == nil)
        #expect(ClaudeResumeMode(rawString: nil) == nil)
    }

    @Test func roundTripsThroughUserDefaultsAndJSON() {
        for mode in ClaudeResumeMode.allCases {
            #expect(ClaudeResumeMode.decodeFromUserDefaults(mode.encodeForUserDefaults()) == mode)
            #expect(ClaudeResumeMode.decodeFromJSON(mode.encodeForJSON()) == mode)
        }
        #expect(ClaudeResumeMode.decodeFromUserDefaults(42) == nil)
    }
}

@Suite("ClaudeResumePrompt")
struct ClaudeResumePromptTests {
    /// Default rendering: pointer (❯) on the recommended first option (summary).
    private let menu = """
    Resuming the full session will consume a substantial portion of your usage limits. We recommend resuming from a summary.
    ❯ 1. Resume from summary (recommended)
      2. Resume full session as-is
      3. Don't ask me again
    """

    @Test func detectsPromptOnlyWhenBothLabelsPresent() {
        #expect(ClaudeResumePrompt.isVisible(in: menu))
        #expect(!ClaudeResumePrompt.isVisible(in: "just some normal claude output\nnothing to see"))
        #expect(!ClaudeResumePrompt.isVisible(in: "Resume from summary mentioned alone"))
    }

    @Test func fullModeMovesDownToSecondOptionThenEnter() {
        #expect(ClaudeResumePrompt.keystrokes(for: .full, in: menu) == [.down, .enter])
    }

    @Test func summaryModeConfirmsDefaultWithEnter() {
        #expect(ClaudeResumePrompt.keystrokes(for: .summary, in: menu) == [.enter])
    }

    @Test func askModeNeverActs() {
        #expect(ClaudeResumePrompt.keystrokes(for: .ask, in: menu) == nil)
    }

    @Test func returnsNilWhenMenuAbsent() {
        #expect(ClaudeResumePrompt.keystrokes(for: .full, in: "no menu here") == nil)
    }

    /// Order-independence: if Claude lists "full" first with the pointer on it,
    /// full needs only Enter and summary needs one Down.
    @Test func adaptsToReorderedOptions() {
        let reordered = """
        ❯ 1. Resume full session as-is
          2. Resume from summary (recommended)
          3. Don't ask me again
        """
        #expect(ClaudeResumePrompt.keystrokes(for: .full, in: reordered) == [.enter])
        #expect(ClaudeResumePrompt.keystrokes(for: .summary, in: reordered) == [.down, .enter])
    }

    /// With no pointer glyph rendered we assume the first option is highlighted.
    @Test func assumesFirstOptionHighlightedWithoutPointer() {
        let noPointer = """
        1. Resume from summary (recommended)
        2. Resume full session as-is
        3. Don't ask me again
        """
        #expect(ClaudeResumePrompt.keystrokes(for: .full, in: noPointer) == [.down, .enter])
    }
}

@Suite("ClaudeResumeAutoResponder")
struct ClaudeResumeAutoResponderTests {
    private let menu = """
    ❯ 1. Resume from summary (recommended)
      2. Resume full session as-is
      3. Don't ask me again
    """

    @Test func firesExactlyOnce() {
        let responder = ClaudeResumeAutoResponder(mode: .full)
        #expect(responder.hasResponded == false)
        #expect(responder.evaluate(screen: menu) == [.down, .enter])
        #expect(responder.hasResponded == true)
        // Subsequent polls (menu still on screen) must not re-send.
        #expect(responder.evaluate(screen: menu) == nil)
    }

    @Test func waitsForMenuBeforeFiring() {
        let responder = ClaudeResumeAutoResponder(mode: .full)
        #expect(responder.evaluate(screen: "claude is starting up…") == nil)
        #expect(responder.hasResponded == false)
        #expect(responder.evaluate(screen: menu) == [.down, .enter])
    }

    @Test func askModeIsAlwaysInert() {
        let responder = ClaudeResumeAutoResponder(mode: .ask)
        #expect(responder.evaluate(screen: menu) == nil)
        #expect(responder.hasResponded == false)
    }
}
