import CmuxTerminalCore
import Testing

@Suite("Terminal keyboard copy mode word motion keys")
struct TerminalKeyboardCopyModeWordMotionKeyTests {
    private static let wKeyCode: UInt16 = 13
    private static let leftArrowKeyCode: UInt16 = 123
    private static let rightArrowKeyCode: UInt16 = 124

    @Test(arguments: [
        (UInt16(13), "w", TerminalKeyboardCopyModeSelectionMove.wordForward),
        (UInt16(11), "b", .wordBackward),
        (UInt16(14), "e", .wordEndForward),
    ])
    func lowercaseKeysResolveWordMotionsInBothModes(
        keyCode: UInt16,
        characters: String,
        move: TerminalKeyboardCopyModeSelectionMove
    ) {
        for hasSelection in [false, true] {
            #expect(
                terminalKeyboardCopyModeAction(
                    keyCode: keyCode,
                    charactersIgnoringModifiers: characters,
                    modifiers: [],
                    hasSelection: hasSelection
                ) == .adjustSelection(move)
            )
        }
    }

    @Test(arguments: [
        (UInt16(13), "w", TerminalKeyboardCopyModeSelectionMove.bigWordForward),
        (UInt16(11), "b", .bigWordBackward),
        (UInt16(14), "e", .bigWordEndForward),
    ])
    func shiftedKeysResolveBigWordMotions(
        keyCode: UInt16,
        characters: String,
        move: TerminalKeyboardCopyModeSelectionMove
    ) {
        #expect(
            terminalKeyboardCopyModeAction(
                keyCode: keyCode,
                charactersIgnoringModifiers: characters,
                modifiers: [.shift],
                hasSelection: false
            ) == .adjustSelection(move)
        )
        #expect(
            terminalKeyboardCopyModeAction(
                keyCode: keyCode,
                charactersIgnoringModifiers: characters.uppercased(),
                modifiers: [],
                hasSelection: true
            ) == .adjustSelection(move)
        )
    }

    @Test func capsLockUppercaseWStaysSmallWordMotion() {
        #expect(
            terminalKeyboardCopyModeAction(
                keyCode: Self.wKeyCode,
                charactersIgnoringModifiers: "W",
                modifiers: [.capsLock],
                hasSelection: false
            ) == .adjustSelection(.wordForward)
        )
    }

    @Test func countPrefixRepeatsWordMotion() {
        var state = TerminalKeyboardCopyModeInputState()
        #expect(
            terminalKeyboardCopyModeResolve(
                keyCode: 20,
                charactersIgnoringModifiers: "3",
                modifiers: [],
                hasSelection: false,
                state: &state
            ) == .consume
        )
        #expect(
            terminalKeyboardCopyModeResolve(
                keyCode: Self.wKeyCode,
                charactersIgnoringModifiers: "w",
                modifiers: [],
                hasSelection: false,
                state: &state
            ) == .perform(.adjustSelection(.wordForward), count: 3)
        )
        #expect(state == TerminalKeyboardCopyModeInputState())
    }

    @Test func optionArrowsAreWordMotions() {
        for modifiers: TerminalKeyboardCopyModeModifiers in [[.option], [.option, .shift]] {
            #expect(
                terminalKeyboardCopyModeAction(
                    keyCode: Self.leftArrowKeyCode,
                    charactersIgnoringModifiers: "\u{F702}",
                    modifiers: modifiers.union(.function),
                    hasSelection: false
                ) == .adjustSelection(.wordBackward)
            )
            #expect(
                terminalKeyboardCopyModeAction(
                    keyCode: Self.rightArrowKeyCode,
                    charactersIgnoringModifiers: "\u{F703}",
                    modifiers: modifiers.union(.function),
                    hasSelection: true
                ) == .adjustSelection(.wordEndForward)
            )
        }
    }

    @Test func plainArrowsStillMoveOneCell() {
        #expect(
            terminalKeyboardCopyModeAction(
                keyCode: Self.leftArrowKeyCode,
                charactersIgnoringModifiers: "\u{F702}",
                modifiers: [.function],
                hasSelection: false
            ) == .adjustSelection(.left)
        )
        #expect(
            terminalKeyboardCopyModeAction(
                keyCode: Self.rightArrowKeyCode,
                charactersIgnoringModifiers: "\u{F703}",
                modifiers: [.function],
                hasSelection: false
            ) == .adjustSelection(.right)
        )
    }

    @Test func optionDoesNotChangeLetterCommandsOrShortcutBypass() {
        #expect(
            terminalKeyboardCopyModeAction(
                keyCode: 38,
                charactersIgnoringModifiers: "j",
                modifiers: [.option],
                hasSelection: false
            ) == .adjustSelection(.down)
        )
        #expect(!terminalKeyboardCopyModeShouldBypassForShortcut(modifiers: [.option]))
        #expect(terminalKeyboardCopyModeShouldBypassForShortcut(modifiers: [.command, .option]))
    }
}

@Suite("Terminal keyboard copy mode word motion targets")
struct TerminalKeyboardCopyModeWordMotionTargetTests {
    /// Resolves a word move over fake rows; returns the landing row and glyph index.
    private func land(
        _ move: TerminalKeyboardCopyModeSelectionMove,
        count: Int = 1,
        rows: [String],
        row: Int = 0,
        index: Int
    ) -> (row: Int, index: Int) {
        guard let motion = TerminalKeyboardCopyModeWordMotion(move) else {
            Issue.record("\(move) is not a word motion")
            return (row, index)
        }
        var current = row
        let landed = motion.resolve(
            count: count,
            line: Array(rows[row]),
            index: index
        ) { forward in
            let next = current + (forward ? 1 : -1)
            guard rows.indices.contains(next) else { return nil }
            current = next
            return Array(rows[next])
        }
        return (current, landed)
    }

    private let sample = ["foo.bar baz_qux  (x)"]

    @Test(arguments: [(0, 3), (3, 4), (4, 8), (8, 17), (17, 18), (10, 17), (7, 8)])
    func smallWordForwardStopsAtClassChanges(from: Int, to: Int) {
        #expect(land(.wordForward, rows: sample, index: from) == (0, to))
    }

    @Test(arguments: [(0, 8), (8, 17), (16, 17)])
    func bigWordForwardSkipsPunctuation(from: Int, to: Int) {
        #expect(land(.bigWordForward, rows: sample, index: from) == (0, to))
    }

    @Test(arguments: [(0, 2), (2, 3), (3, 6), (6, 14), (7, 14), (14, 17)])
    func smallWordEndForwardLandsOnLastGlyph(from: Int, to: Int) {
        #expect(land(.wordEndForward, rows: sample, index: from) == (0, to))
    }

    @Test(arguments: [(0, 6), (6, 14), (14, 19)])
    func bigWordEndForwardLandsOnLastGlyph(from: Int, to: Int) {
        #expect(land(.bigWordEndForward, rows: sample, index: from) == (0, to))
    }

    @Test(arguments: [(8, 4), (4, 3), (3, 0), (17, 8), (10, 8), (16, 8)])
    func smallWordBackwardLandsOnWordStart(from: Int, to: Int) {
        #expect(land(.wordBackward, rows: sample, index: from) == (0, to))
    }

    @Test(arguments: [(17, 8), (8, 0), (5, 0)])
    func bigWordBackwardLandsOnWordStart(from: Int, to: Int) {
        #expect(land(.bigWordBackward, rows: sample, index: from) == (0, to))
    }

    @Test func countRepeatsTheMotion() {
        #expect(land(.wordForward, count: 3, rows: sample, index: 0) == (0, 8))
        #expect(land(.wordBackward, count: 2, rows: sample, index: 17) == (0, 4))
        #expect(land(.wordEndForward, count: 2, rows: sample, index: 0) == (0, 3))
    }

    @Test func wordForwardCrossesRowsAndStopsOnEmptyRows() {
        let rows = ["echo hi", "", "  next line"]
        #expect(land(.wordForward, rows: rows, row: 0, index: 5) == (1, 0))
        #expect(land(.wordForward, rows: rows, row: 1, index: 0) == (2, 2))
        #expect(land(.wordForward, count: 2, rows: rows, row: 0, index: 5) == (2, 2))
    }

    @Test func wordForwardSkipsWhitespaceOnlyRows() {
        #expect(land(.wordForward, rows: ["a", "   ", "b"], index: 0) == (2, 0))
    }

    @Test func wordEndForwardSkipsEmptyRows() {
        let rows = ["echo hi", "", "  next line"]
        #expect(land(.wordEndForward, rows: rows, row: 0, index: 6) == (2, 5))
    }

    @Test func wordBackwardCrossesRowsAndStopsOnEmptyRows() {
        let rows = ["echo hi", "", "  next line"]
        #expect(land(.wordBackward, rows: rows, row: 2, index: 2) == (1, 0))
        #expect(land(.wordBackward, rows: rows, row: 1, index: 0) == (0, 5))
        #expect(land(.wordBackward, count: 2, rows: rows, row: 2, index: 2) == (0, 5))
    }

    @Test func motionsStopAtTheScrollbackEdges() {
        let rows = ["foo bar"]
        #expect(land(.wordForward, rows: rows, index: 4) == (0, 6))
        #expect(land(.wordForward, count: 9, rows: rows, index: 0) == (0, 6))
        #expect(land(.wordEndForward, rows: rows, index: 6) == (0, 6))
        #expect(land(.wordBackward, rows: rows, index: 0) == (0, 0))
        #expect(land(.bigWordBackward, count: 9, rows: ["  foo"], index: 4) == (0, 0))
    }

    @Test func forwardMotionsAtTheScrollbackEdgeNeverMoveBackward() {
        let rows = ["foo"]
        for move: TerminalKeyboardCopyModeSelectionMove in [
            .wordForward, .bigWordForward, .wordEndForward, .bigWordEndForward,
        ] {
            #expect(land(move, rows: rows, index: 3) == (0, 3))
            #expect(land(move, count: 4, rows: rows, index: 10) == (0, 10))
        }
        // A scan that crossed rows lands on the new row's last glyph.
        #expect(land(.wordForward, rows: ["foo", "   "], index: 3) == (1, 2))
    }

    @Test func cursorInTrailingEmptyCellsActsAsBlank() {
        let rows = ["foo", "bar"]
        #expect(land(.wordForward, rows: rows, index: 10) == (1, 0))
        #expect(land(.wordEndForward, rows: rows, index: 10) == (1, 2))
        #expect(land(.wordBackward, rows: rows, index: 10) == (0, 0))
    }

    @Test func wideGlyphsCountAsOneIndex() {
        #expect(land(.wordForward, rows: ["日本語 test"], index: 0) == (0, 4))
        #expect(land(.wordEndForward, rows: ["日本語 test"], index: 0) == (0, 2))
    }

    @Test func cellAndRowMovesAreNotWordMotions() {
        let moves: [TerminalKeyboardCopyModeSelectionMove] = [
            .left, .right, .up, .down, .pageUp, .pageDown,
            .home, .end, .beginningOfLine, .endOfLine,
        ]
        for move in moves {
            #expect(TerminalKeyboardCopyModeWordMotion(move) == nil)
        }
    }
}
