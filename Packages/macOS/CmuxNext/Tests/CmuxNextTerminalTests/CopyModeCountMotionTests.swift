import CmuxNextCopyMode
import Testing

/// Copy mode's count prefixes and word motions. Leo, 2026-11-17: "we can make these WITH MOTION."
/// A digit count before a motion repeats it (`5j` moves five rows down, `3w` three words on), and
/// `w`, `b`, `e` (and `W`, `B`, `E`) move by words. Ghostty's `adjust_selection:left` and `:right`
/// step over text cells only, so a word motion is a signed number of those steps.
@Suite struct CopyModeCountMotionTests {
    /// Types `keys` (plain characters, no modifiers) and returns the last resolution.
    private func type(_ keys: String, hasSelection: Bool = false) -> CopyModeResolution {
        var state = CopyModeInputState()
        var last = CopyModeResolution.consume
        for character in keys {
            let text = String(character)
            let uppercase = character.isUppercase
            last = CopyModeKeys().resolve(keyCode: 0, charactersIgnoringModifiers: uppercase ? text : text.lowercased(),
                                          modifiers: uppercase ? [.shift] : [], hasSelection: hasSelection, state: &state)
        }
        return last
    }

    // MARK: Count prefixes

    @Test func fiveJMovesFiveRowsDown() {
        #expect(type("5") == .consume)
        #expect(type("5j") == .perform(.adjustSelection(.down), count: 5))
        #expect(type("5j", hasSelection: true) == .perform(.adjustSelection(.down), count: 5))
    }

    @Test func threeWMovesThreeWordsOn() {
        #expect(type("3w") == .perform(.moveWord(.wordForward), count: 3))
        #expect(type("3W") == .perform(.moveWord(.bigWordForward), count: 3))
        #expect(type("2b") == .perform(.moveWord(.wordBackward), count: 2))
        #expect(type("4e") == .perform(.moveWord(.wordEnd), count: 4))
    }

    @Test func zeroExtendsACountButAloneGoesToLineStart() {
        #expect(type("10j") == .perform(.adjustSelection(.down), count: 10))
        #expect(type("0") == .perform(.adjustSelection(.beginningOfLine), count: 1))
        #expect(type("j") == .perform(.adjustSelection(.down), count: 1))
        #expect(type("99999k") == .perform(.adjustSelection(.up), count: CopyModeKeys.maxCount))
    }

    @Test func aCountIsSpentByOneMotion() {
        var state = CopyModeInputState()
        let keys = CopyModeKeys()
        _ = keys.resolve(keyCode: 0, charactersIgnoringModifiers: "3", modifiers: [], hasSelection: false, state: &state)
        _ = keys.resolve(keyCode: 0, charactersIgnoringModifiers: "w", modifiers: [], hasSelection: false, state: &state)
        #expect(state.countPrefix == nil)
        #expect(keys.resolve(keyCode: 0, charactersIgnoringModifiers: "w", modifiers: [], hasSelection: false, state: &state)
            == .perform(.moveWord(.wordForward), count: 1))
    }

    // MARK: Word steps

    private func steps(_ rows: [String], _ row: Int, _ column: Int, _ move: CopyModeWordMove, _ count: Int = 1) -> Int {
        CopyModeWords.steps(rows: rows, row: row, column: column, move: move, count: count)
    }

    @Test func threeWLandsOnTheFourthWord() {
        let rows = ["foo bar baz qux"]
        #expect(steps(rows, 0, 0, .wordForward) == 3)
        #expect(steps(rows, 0, 0, .wordForward, 3) == 9, "f-o-o b-a-r b-a-z, then q")
        #expect(steps(rows, 0, 12, .wordBackward, 3) == -9, "from q back to baz, bar, foo")
        #expect(steps(rows, 0, 0, .wordEnd) == 2)
        #expect(steps(rows, 0, 0, .wordEnd, 2) == 5)
    }

    @Test func punctuationSplitsWordsButNotWORDs() {
        let rows = ["foo.bar baz"]
        #expect(steps(rows, 0, 0, .wordForward) == 3, "onto the dot")
        #expect(steps(rows, 0, 0, .wordForward, 2) == 4, "onto bar")
        #expect(steps(rows, 0, 0, .bigWordForward) == 7, "onto baz")
        #expect(steps(rows, 0, 8, .bigWordBackward) == -7)
    }

    @Test func wordsContinueOnTheNextRow() {
        let rows = ["echo hi", "  ls -la"]
        #expect(steps(rows, 0, 5, .wordForward) == 2, "hi, then ls")
        #expect(steps(rows, 0, 5, .wordForward, 2) == 4, "then the dash")
        #expect(steps(rows, 1, 2, .wordBackward) == -2, "back to hi")
    }

    @Test func aCursorOnABlankCellCountsItsFirstStep() {
        let rows = ["$ ls", ""]
        #expect(steps(rows, 0, 5, .wordBackward) == -2, "left lands on s, then l")
        #expect(steps(rows, 0, 1, .wordForward) == 1, "right lands on l, a word start")
        #expect(steps(rows, 0, 5, .wordForward) == 0, "nothing after the prompt")
    }

    @Test func aCountPastTheLastWordStopsAtTheEdge() {
        #expect(steps(["a b"], 0, 0, .wordForward, 5) == 1)
        #expect(steps(["a b"], 0, 2, .wordBackward, 5) == -1)
        #expect(steps([], 0, 0, .wordForward, 3) == 0)
    }

    @Test func wideGlyphsTakeTwoColumns() {
        #expect(CopyModeWords.cellWidth("日") == 2)
        #expect(CopyModeWords.cellWidth("a") == 1)
        let rows = ["日本 x"]
        #expect(steps(rows, 0, 5, .wordBackward) == -2, "x is at column 5; 日本 is one word")
        #expect(steps(rows, 0, 0, .wordEnd) == 1)
    }
}
