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
                TerminalKeyboardCopyModeResolution.action(
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
                TerminalKeyboardCopyModeResolution.action(
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
            TerminalKeyboardCopyModeResolution.action(
                keyCode: 29,
                charactersIgnoringModifiers: "0",
                modifiers: [],
                hasSelection: false
            ) == .adjustSelection(.beginningOfLine)
        )
        #expect(
            TerminalKeyboardCopyModeResolution.action(
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
            TerminalKeyboardCopyModeResolution.resolve(
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
            TerminalKeyboardCopyModeResolution.resolve(
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
            TerminalKeyboardCopyModeResolution.resolve(
                keyCode: 40,
                charactersIgnoringModifiers: "k",
                modifiers: [],
                hasSelection: false,
                state: &state
            ) == .perform(.adjustSelection(.up), count: 1)
        )
        #expect(state == TerminalKeyboardCopyModeInputState())
    }

    @Test func uppercaseRawYWithoutShiftModifierYanksLineImmediately() {
        var state = TerminalKeyboardCopyModeInputState()

        #expect(
            terminalKeyboardCopyModeResolve(
                keyCode: 16,
                charactersIgnoringModifiers: "Y",
                modifiers: [],
                hasSelection: false,
                state: &state
            ) == .perform(.copyLineAndExit, count: 1)
        )
        #expect(state == TerminalKeyboardCopyModeInputState())
    }

    @Test func uppercaseRawVRestartsVisualLineSelectionWhenSelectionExists() {
        #expect(
            terminalKeyboardCopyModeAction(
                keyCode: 9,
                charactersIgnoringModifiers: "V",
                modifiers: [],
                hasSelection: true
            ) == .startLineSelection
        )
    }

    @Test func uppercaseRawVStartsVisualLineSelection() {
        #expect(
            terminalKeyboardCopyModeAction(
                keyCode: 9,
                charactersIgnoringModifiers: "V",
                modifiers: [],
                hasSelection: false
            ) == .startLineSelection
        )
    }

    @Test func shiftVRestartsVisualLineSelectionWhenSelectionExists() {
        #expect(
            terminalKeyboardCopyModeAction(
                keyCode: 9,
                charactersIgnoringModifiers: "v",
                modifiers: [.shift],
                hasSelection: true
            ) == .startLineSelection
        )
    }

    @Test func shiftVStartsVisualLineSelection() {
        #expect(
            terminalKeyboardCopyModeAction(
                keyCode: 9,
                charactersIgnoringModifiers: "v",
                modifiers: [.shift],
                hasSelection: false
            ) == .startLineSelection
        )
    }

    @Test func capsLockUppercaseVStartsCharacterSelection() {
        #expect(
            terminalKeyboardCopyModeAction(
                keyCode: 9,
                charactersIgnoringModifiers: "V",
                modifiers: [.capsLock],
                hasSelection: false
            ) == .startSelection
        )
    }

    @Test func capsLockUppercaseYStartsPendingYankLine() {
        var state = TerminalKeyboardCopyModeInputState()

        #expect(
            terminalKeyboardCopyModeResolve(
                keyCode: 16,
                charactersIgnoringModifiers: "Y",
                modifiers: [.capsLock],
                hasSelection: false,
                state: &state
            ) == .consume
        )
        #expect(state == TerminalKeyboardCopyModeInputState(pendingYankLine: true))
    }

    @Test func capsLockUppercaseGStartsPendingTopJump() {
        var state = TerminalKeyboardCopyModeInputState()

        #expect(
            terminalKeyboardCopyModeResolve(
                keyCode: 5,
                charactersIgnoringModifiers: "G",
                modifiers: [.capsLock],
                hasSelection: false,
                state: &state
            ) == .consume
        )
        #expect(state == TerminalKeyboardCopyModeInputState(pendingG: true))
    }

    @Test func pendingGThenRawUppercaseGResolvesBottomJump() {
        var state = TerminalKeyboardCopyModeInputState(pendingG: true)

        #expect(
            terminalKeyboardCopyModeResolve(
                keyCode: 5,
                charactersIgnoringModifiers: "G",
                modifiers: [],
                hasSelection: false,
                state: &state
            ) == .perform(.scrollToBottom, count: 1)
        )
        #expect(state == TerminalKeyboardCopyModeInputState())
    }

    @Test func capsLockUppercaseNSearchesForward() {
        #expect(
            terminalKeyboardCopyModeAction(
                keyCode: 45,
                charactersIgnoringModifiers: "N",
                modifiers: [.capsLock],
                hasSelection: false
            ) == .searchNext
        )
    }
}

@Suite("Terminal keyboard copy mode cursor")
struct TerminalKeyboardCopyModeCursorPackageTests {
    @Test func motionThenVisualSelectionUsesMovedCursorAsAnchor() {
        var cursor = TerminalKeyboardCopyModeCursor(row: 8, column: 7)

        let moveAction = TerminalKeyboardCopyModeResolution.action(
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
            TerminalKeyboardCopyModeResolution.action(
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

    @Test func visualLineMovementKeepsOffscreenEndpointAbsolute() {
        var selection = TerminalKeyboardCopyModeVisualLineSelection(
            anchorScreenRow: 10,
            endpointScreenRow: 50
        )

        let move = selection.moveEndpoint(
            .down,
            count: 1,
            currentColumn: 7,
            viewportRows: 20,
            viewportColumns: 80,
            scrollOffset: 100,
            totalRows: 200
        )

        #expect(selection.selectedRows == 10 ... 51)
        #expect(move.cursor == TerminalKeyboardCopyModeCursor(row: 0, column: 7))
        #expect(move.scrollDelta == 0)
    }

    @Test func visualLineMovementScrollsOnlyVisibleEndpointOverflow() {
        var selection = TerminalKeyboardCopyModeVisualLineSelection(
            anchorScreenRow: 110,
            endpointScreenRow: 119
        )

        let move = selection.moveEndpoint(
            .down,
            count: 1,
            currentColumn: 4,
            viewportRows: 20,
            viewportColumns: 80,
            scrollOffset: 100,
            totalRows: 200
        )

        #expect(selection.selectedRows == 110 ... 120)
        #expect(move.cursor == TerminalKeyboardCopyModeCursor(row: 19, column: 4))
        #expect(move.scrollDelta == 1)
    }

    @Test func visualLineBoundaryMovementTargetsLastScreenRow() {
        var selection = TerminalKeyboardCopyModeVisualLineSelection(
            anchorScreenRow: 40,
            endpointScreenRow: 95
        )

        let moved = selection.moveEndpointToBoundary(.end, totalRows: 100)

        #expect(moved)
        #expect(selection.selectedRows == 40 ... 99)
    }

    @Test func visualLineRuntimeRowsPreserveSelectionDirection() {
        var forward = TerminalKeyboardCopyModeVisualLineSelection(
            anchorScreenRow: 10,
            endpointScreenRow: 20
        )
        var reverse = TerminalKeyboardCopyModeVisualLineSelection(
            anchorScreenRow: 20,
            endpointScreenRow: 10
        )

        forward.replaceSelectedRows(3 ... 7)
        reverse.replaceSelectedRows(3 ... 7)

        #expect(forward.anchorScreenRow == 3)
        #expect(forward.endpointScreenRow == 7)
        #expect(reverse.anchorScreenRow == 7)
        #expect(reverse.endpointScreenRow == 3)
        #expect(forward.selectedRows == 3 ... 7)
        #expect(reverse.selectedRows == 3 ... 7)
    }

    @Test func visualLineMovementKeepsClippedBottomEndpointAbsolute() {
        var selection = TerminalKeyboardCopyModeVisualLineSelection(
            anchorScreenRow: 40,
            endpointScreenRow: 95
        )

        let move = selection.moveEndpoint(
            .down,
            count: 1,
            currentColumn: 4,
            viewportRows: 20,
            viewportColumns: 80,
            scrollOffset: 76,
            totalRows: 100
        )

        #expect(selection.selectedRows == 40 ... 96)
        #expect(move.cursor == TerminalKeyboardCopyModeCursor(row: 19, column: 4))
        #expect(move.scrollDelta == 1)
    }
}
