import Testing
@testable import CMUXAgentLaunch

/// Screens shaped like Claude Code 2.1 and Codex draw them, as the VT text a
/// terminal exports: SGR 2 (faint) marks the placeholder and suggestions.
@Suite("Agent prompt input reader")
struct AgentPromptInputReaderTests {
    private let rule = "\u{1B}[38;2;136;136;136m" + String(repeating: "─", count: 40) + "\u{1B}[39m"
    private let claude = AgentPromptInputReader(dialect: .claudeCode)
    private let codex = AgentPromptInputReader(dialect: .codex)

    private func claudeScreen(_ inputLines: [String]) -> String {
        ([
            "\u{1B}[38;2;153;153;153mv2.1.283\u{1B}[39m",
            "❯ an earlier prompt shown in the transcript",
            "⏺ Done.",
            rule,
        ] + inputLines + [
            rule,
            "  \u{1B}[38;2;255;193;7m⏵⏵ auto mode on\u{1B}[38;2;153;153;153m (shift+tab to cycle)\u{1B}[39m",
        ]).joined(separator: "\r\n")
    }

    @Test func blankInputIsEmpty() {
        #expect(claude.state(screen: claudeScreen(["\u{1B}[39m❯\u{00A0}"])) == .empty)
    }

    @Test func dimPlaceholderIsEmpty() {
        let screen = claudeScreen(["\u{1B}[39m❯\u{00A0}\u{1B}[2mTry \"fix typecheck errors\"\u{1B}[22m"])
        #expect(claude.state(screen: screen) == .empty)
    }

    @Test func typedDraftHasText() {
        #expect(claude.state(screen: claudeScreen(["❯\u{00A0}hello draft"])) == .hasText)
    }

    @Test func draftOnALaterLineOfTheBoxHasText() {
        #expect(claude.state(screen: claudeScreen(["❯\u{00A0}", "  second line of a draft"])) == .hasText)
    }

    @Test func draftAfterAResetFromFaintHasText() {
        let screen = claudeScreen(["❯ \u{1B}[2mdim\u{1B}[0m typed"])
        #expect(claude.state(screen: screen) == .hasText)
    }

    @Test func extendedColorArgumentsAreNotReadAsFaint() {
        // 38;2;2;2;2 is an RGB color whose components are 2, not SGR 2.
        let screen = claudeScreen(["❯ \u{1B}[38;2;2;2;2mtyped\u{1B}[39m"])
        #expect(claude.state(screen: screen) == .hasText)
    }

    @Test func missingInputBoxIsUnknown() {
        #expect(claude.state(screen: "some shell output\r\n$ ") == .unknown)
        let unclosed = [rule, "❯ "].joined(separator: "\n")
        #expect(claude.state(screen: unclosed) == .unknown, "No closing rule: the box is cut off")
    }

    @Test func codexReadsOnlyItsPromptLine() {
        let empty = "› \u{1B}[2mAsk Codex to do anything\u{1B}[22m\r\n\r\n  \u{1B}[2m? for shortcuts\u{1B}[22m"
        #expect(codex.state(screen: empty) == .empty)
        #expect(codex.state(screen: "› refactor this\r\n\r\n  ? for shortcuts") == .hasText)
    }

    @Test func codexDraftBelowAnEmptyFirstLineHasText() {
        let screen = "› \r\n  second line of a draft\r\n\r\n  \u{1B}[2m? for shortcuts\u{1B}[22m"
        #expect(codex.state(screen: screen) == .hasText)
    }

    @Test(arguments: ["\u{1B}[38m", "\u{1B}[48m", "\u{1B}[38:2::1:2:3m"])
    func truncatedColorParametersDoNotTrap(sequence: String) {
        #expect(claude.state(screen: claudeScreen(["❯ \(sequence)typed"])) == .hasText)
    }

    @Test func menuRowsAreNotAnEmptyInput() {
        // A selection menu also marks its row with the glyph; its label is
        // bright, so the reader never mistakes it for an empty input.
        let menu = "\u{1B}[7m\u{1B}[1m› 1. Update now\u{1B}[27m\u{1B}[22m\r\n  2. Skip"
        #expect(codex.state(screen: menu) == .hasText)
    }

    @Test func oscAndCharsetSequencesAreSkipped() {
        let screen = claudeScreen(["\u{1B}(B\u{1B}]8;;https://example.com\u{07}\u{1B}]8;;\u{07}❯\u{00A0}"])
        #expect(claude.state(screen: screen) == .empty)
    }
}
