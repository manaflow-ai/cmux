import CmuxTerminalCore
import Testing

@Suite("Terminal keyboard copy mode resolver")
struct TerminalKeyboardCopyModeResolverTests {
    @Test func resolvesAllVimKeysWithNonASCIILayoutFallback() {
        let asciiProvider: (UInt16) -> String? = { keyCode in
            switch keyCode {
            case 4: return "h"
            case 38: return "j"
            case 40: return "k"
            case 37: return "l"
            default: return nil
            }
        }
        let cases: [(keyCode: UInt16, characters: String, action: TerminalKeyboardCopyModeAction)] = [
            (4, "ㅗ", .adjustSelection(.left)),
            (38, "ㅓ", .adjustSelection(.down)),
            (40, "ㅏ", .adjustSelection(.up)),
            (37, "ㅣ", .adjustSelection(.right)),
        ]

        for testCase in cases {
            #expect(
                terminalKeyboardCopyModeAction(
                    keyCode: testCase.keyCode,
                    charactersIgnoringModifiers: testCase.characters,
                    modifiers: [],
                    hasSelection: false,
                    asciiCharacterProvider: asciiProvider
                ) == testCase.action
            )
        }
    }

    @Test func ignoresCapsLockForAllVimMotionKeys() {
        let cases: [(keyCode: UInt16, characters: String, action: TerminalKeyboardCopyModeAction)] = [
            (4, "h", .adjustSelection(.left)),
            (38, "j", .adjustSelection(.down)),
            (40, "k", .adjustSelection(.up)),
            (37, "l", .adjustSelection(.right)),
        ]

        for testCase in cases {
            #expect(
                terminalKeyboardCopyModeAction(
                    keyCode: testCase.keyCode,
                    charactersIgnoringModifiers: testCase.characters,
                    modifiers: [.capsLock],
                    hasSelection: false
                ) == testCase.action
            )
        }
    }

    @Test func lineBoundaryKeysMoveCursorOutsideVisualMode() {
        #expect(
            terminalKeyboardCopyModeAction(
                keyCode: 29,
                charactersIgnoringModifiers: "0",
                modifiers: [],
                hasSelection: false
            ) == .adjustSelection(.beginningOfLine)
        )
        #expect(
            terminalKeyboardCopyModeAction(
                keyCode: 21,
                charactersIgnoringModifiers: "4",
                modifiers: [.shift],
                hasSelection: false
            ) == .adjustSelection(.endOfLine)
        )
    }

    @Test func zeroWithoutExistingCountActsAsBeginningOfLineMotion() {
        var state = TerminalKeyboardCopyModeInputState()

        #expect(
            terminalKeyboardCopyModeResolve(
                keyCode: 29,
                charactersIgnoringModifiers: "0",
                modifiers: [],
                hasSelection: false,
                state: &state
            ) == .perform(.adjustSelection(.beginningOfLine), count: 1)
        )
        #expect(state == TerminalKeyboardCopyModeInputState())
    }

    @Test func unmatchedGPrefixClearsCountBeforeResolvingFollowup() {
        var state = TerminalKeyboardCopyModeInputState(countPrefix: 3, pendingG: true)

        #expect(
            terminalKeyboardCopyModeResolve(
                keyCode: 38,
                charactersIgnoringModifiers: "j",
                modifiers: [],
                hasSelection: false,
                state: &state
            ) == .perform(.adjustSelection(.down), count: 1)
        )
        #expect(state == TerminalKeyboardCopyModeInputState())
    }

    @Test func unmatchedYankLinePrefixClearsCountBeforeResolvingFollowup() {
        var state = TerminalKeyboardCopyModeInputState(countPrefix: 3, pendingYankLine: true)

        #expect(
            terminalKeyboardCopyModeResolve(
                keyCode: 40,
                charactersIgnoringModifiers: "k",
                modifiers: [],
                hasSelection: false,
                state: &state
            ) == .perform(.adjustSelection(.up), count: 1)
        )
        #expect(state == TerminalKeyboardCopyModeInputState())
    }
}

@Suite("Terminal keyboard copy mode cursor")
struct TerminalKeyboardCopyModeCursorPackageTests {
    @Test func motionThenVisualSelectionUsesMovedCursorAsAnchor() {
        var cursor = TerminalKeyboardCopyModeCursor(row: 8, column: 7)

        let moveAction = terminalKeyboardCopyModeAction(
            keyCode: 38,
            charactersIgnoringModifiers: "j",
            modifiers: [],
            hasSelection: false
        )
        #expect(moveAction == .adjustSelection(.down))
        if case let .adjustSelection(move)? = moveAction {
            #expect(cursor.move(move, count: 1, rows: 20, columns: 40) == 0)
        }

        #expect(
            terminalKeyboardCopyModeAction(
                keyCode: 9,
                charactersIgnoringModifiers: "v",
                modifiers: [],
                hasSelection: false
            ) == .startSelection
        )
        #expect(cursor.clamped(rows: 20, columns: 40) == TerminalKeyboardCopyModeCursor(row: 9, column: 7))
    }

    @Test func cursorSelectionXRangeKeepsLeftToRightDragAtRightEdge() throws {
        let range = try #require(
            terminalKeyboardCopyModeCursorSelectionXRange(
                rectMinX: 99.5,
                rectMaxX: 120,
                boundsWidth: 100
            )
        )

        #expect(abs(range.startX - 98) < 0.0001)
        #expect(abs(range.endX - 99) < 0.0001)
    }

    @Test func viewportOffsetDeltaKeepsCursorOnSameTextAfterJump() {
        var cursor = TerminalKeyboardCopyModeCursor(row: 10, column: 4)

        cursor.shiftForViewportScroll(lineDelta: 3, rows: 20, columns: 8)

        #expect(cursor == TerminalKeyboardCopyModeCursor(row: 7, column: 4))
    }

    @Test func clippedBackingRowsDoNotDelayEdgeScroll() {
        let rows = terminalKeyboardCopyModeVisibleViewportRows(
            backingRows: 12,
            viewHeight: 100,
            cellHeight: 10
        )
        var cursor = TerminalKeyboardCopyModeCursor(row: rows - 1, column: 4)

        #expect(rows == 10)
        #expect(cursor.move(.down, count: 1, rows: rows, columns: 8) == 1)
        #expect(cursor == TerminalKeyboardCopyModeCursor(row: rows - 1, column: 4))
    }
}
