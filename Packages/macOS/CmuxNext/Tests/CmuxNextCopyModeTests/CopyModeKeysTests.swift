import CmuxNextCopyMode
import CoreGraphics
import Testing

/// The copy-mode key table, ported from the old app's
/// `TerminalKeyboardCopyModeResolverTests` (same cases) plus count prefixes,
/// two-key commands, the shortcut bypass, and the cursor box geometry.
@Suite("Copy mode keys")
struct CopyModeKeysTests {
    private func action(_ keyCode: UInt16, _ characters: String, _ modifiers: CopyModeModifiers = [],
                        selecting: Bool = false) -> CopyModeAction? {
        CopyModeKeys().action(keyCode: keyCode, charactersIgnoringModifiers: characters, modifiers: modifiers,
                            hasSelection: selecting)
    }

    private func resolve(_ keys: [(UInt16, String, CopyModeModifiers)], selecting: Bool = false,
                         state: inout CopyModeInputState) -> [CopyModeResolution] {
        keys.map { key in
            CopyModeKeys().resolve(keyCode: key.0, charactersIgnoringModifiers: key.1, modifiers: key.2,
                                 hasSelection: selecting, state: &state)
        }
    }

    @Test func resolvesVimKeysUnderANonASCIILayout() {
        let ascii: (UInt16) -> String? = { [4: "h", 38: "j", 40: "k", 37: "l"][$0] }
        let cases: [(UInt16, String, CopyModeAction)] = [
            (4, "ㅗ", .adjustSelection(.left)),
            (38, "ㅓ", .adjustSelection(.down)),
            (40, "ㅏ", .adjustSelection(.up)),
            (37, "ㅣ", .adjustSelection(.right)),
        ]
        for (keyCode, characters, expected) in cases {
            #expect(CopyModeKeys(asciiCharacter: ascii).action(keyCode: keyCode, charactersIgnoringModifiers: characters,
                                                               modifiers: [], hasSelection: false) == expected)
        }
    }

    @Test func ignoresCapsLockForMotionKeys() {
        #expect(action(4, "h", [.capsLock]) == .adjustSelection(.left))
        #expect(action(38, "j", [.capsLock]) == .adjustSelection(.down))
        #expect(action(40, "k", [.capsLock]) == .adjustSelection(.up))
        #expect(action(37, "l", [.capsLock]) == .adjustSelection(.right))
    }

    @Test func lineBoundaryKeys() {
        #expect(action(29, "0") == .adjustSelection(.beginningOfLine))
        #expect(action(21, "4", [.shift]) == .adjustSelection(.endOfLine))
        #expect(action(21, "$") == .adjustSelection(.endOfLine))
        #expect(action(21, "4") == nil)
    }

    @Test func zeroWithoutACountIsStartOfLine() {
        var state = CopyModeInputState()
        #expect(resolve([(29, "0", [])], state: &state) == [.perform(.adjustSelection(.beginningOfLine), count: 1)])
        #expect(state == CopyModeInputState())
    }

    @Test func countPrefixRepeatsTheNextCommand() {
        var state = CopyModeInputState()
        let results = resolve([(19, "2", []), (29, "0", []), (38, "j", [])], state: &state)
        #expect(results == [.consume, .consume, .perform(.adjustSelection(.down), count: 20)])
        #expect(state == CopyModeInputState())
    }

    @Test func countIsClamped() {
        var state = CopyModeInputState()
        let keys = Array(repeating: (UInt16(25), "9", CopyModeModifiers()), count: 6) + [(38, "j", [])]
        #expect(resolve(keys, state: &state).last == .perform(.adjustSelection(.down), count: CopyModeKeys.maxCount))
    }

    @Test func unmatchedGPrefixClearsTheCount() {
        var state = CopyModeInputState(countPrefix: 3, pendingG: true)
        #expect(resolve([(38, "j", [])], state: &state) == [.perform(.adjustSelection(.down), count: 1)])
        #expect(state == CopyModeInputState())
    }

    @Test func unmatchedYankPrefixClearsTheCount() {
        var state = CopyModeInputState(countPrefix: 3, pendingYankLine: true)
        #expect(resolve([(40, "k", [])], state: &state) == [.perform(.adjustSelection(.up), count: 1)])
        #expect(state == CopyModeInputState())
    }

    @Test func ggAndGJumpToTopAndBottom() {
        var state = CopyModeInputState()
        #expect(resolve([(5, "g", []), (5, "g", [])], state: &state) == [.consume, .perform(.scrollToTop, count: 1)])
        #expect(resolve([(5, "g", [.shift])], state: &state) == [.perform(.scrollToBottom, count: 1)])
        #expect(resolve([(5, "g", []), (5, "g", [])], selecting: true, state: &state).last
            == .perform(.adjustSelection(.home), count: 1))
    }

    @Test func pendingGThenUppercaseGJumpsToBottom() {
        var state = CopyModeInputState(pendingG: true)
        #expect(resolve([(5, "G", [])], state: &state) == [.perform(.scrollToBottom, count: 1)])
        #expect(state == CopyModeInputState())
    }

    @Test func yyCopiesCountedLines() {
        var state = CopyModeInputState()
        let results = resolve([(20, "3", []), (16, "y", []), (16, "y", [])], state: &state)
        #expect(results == [.consume, .consume, .perform(.copyLineAndExit, count: 3)])
    }

    @Test func yCopiesTheSelection() {
        var state = CopyModeInputState()
        #expect(resolve([(16, "y", [])], selecting: true, state: &state) == [.perform(.copyAndExit, count: 1)])
    }

    @Test func uppercaseYWithoutShiftCopiesTheLine() {
        var state = CopyModeInputState()
        #expect(resolve([(16, "Y", [])], state: &state) == [.perform(.copyLineAndExit, count: 1)])
        #expect(state == CopyModeInputState())
    }

    @Test func vAndUppercaseVStartSelections() {
        #expect(action(9, "v") == .startSelection)
        #expect(action(9, "v", selecting: true) == .clearSelection)
        #expect(action(9, "V") == .startLineSelection)
        #expect(action(9, "V", selecting: true) == .startLineSelection)
        #expect(action(9, "v", [.shift]) == .startLineSelection)
        #expect(action(9, "v", [.shift], selecting: true) == .startLineSelection)
    }

    @Test func capsLockCapitalsAreLowercaseCommands() {
        #expect(action(9, "V", [.capsLock]) == .startSelection)
        #expect(action(45, "N", [.capsLock]) == .searchNext)
        var state = CopyModeInputState()
        #expect(resolve([(16, "Y", [.capsLock])], state: &state) == [.consume])
        #expect(state == CopyModeInputState(pendingYankLine: true))
        state = CopyModeInputState()
        #expect(resolve([(5, "G", [.capsLock])], state: &state) == [.consume])
        #expect(state == CopyModeInputState(pendingG: true))
    }

    @Test func scrollKeysScrollOrExtend() {
        #expect(action(32, "u", [.control]) == .scrollHalfPage(-1))
        #expect(action(2, "d", [.control]) == .scrollHalfPage(1))
        #expect(action(11, "b", [.control]) == .scrollPage(-1))
        #expect(action(3, "f", [.control]) == .scrollPage(1))
        #expect(action(16, "y", [.control]) == .scrollLines(-1))
        #expect(action(14, "e", [.control]) == .scrollLines(1))
        #expect(action(32, "u", [.control], selecting: true) == .adjustSelection(.pageUp))
        #expect(action(116, "") == .scrollPage(-1))
        #expect(action(121, "", selecting: true) == .adjustSelection(.pageDown))
        #expect(action(115, "") == .scrollToTop)
        #expect(action(119, "", selecting: true) == .adjustSelection(.end))
    }

    @Test func promptsSearchAndExit() {
        #expect(action(33, "{") == .jumpToPrompt(-1))
        #expect(action(33, "[", [.shift]) == .jumpToPrompt(-1))
        #expect(action(30, "}") == .jumpToPrompt(1))
        #expect(action(44, "/") == .startSearch)
        #expect(action(45, "n") == .searchNext)
        #expect(action(45, "n", [.shift]) == .searchPrevious)
        #expect(action(12, "q") == .exit)
        #expect(action(53, "") == .exit)
    }

    @Test func otherKeysAreSwallowed() {
        var state = CopyModeInputState(countPrefix: 4)
        #expect(resolve([(0, "a", [])], state: &state) == [.consume])
        #expect(state == CopyModeInputState())
        #expect(action(0, "a", [.control]) == nil)
    }

    @Test func commandChordsBypassCopyMode() {
        #expect(CopyModeKeys.bypassesForShortcut([.command]))
        #expect(CopyModeKeys.bypassesForShortcut([.command, .shift]))
        #expect(!CopyModeKeys.bypassesForShortcut([.control]))
        #expect(!CopyModeKeys.bypassesForShortcut([.capsLock, .shift]))
    }

    @Test func cursorFrameFlipsToAppKitAndCoversWideCells() throws {
        let frame = try #require(CopyModeCursorFrame(cellWidth: 8, cellHeight: 16, paddingLeft: 4, paddingTop: 2,
                                                     viewHeight: 400))
        #expect(frame.rect(column: 0, row: 0, widthCells: 1) == CGRect(x: 4, y: 382, width: 8, height: 16))
        #expect(frame.rect(column: 3, row: 2, widthCells: 2) == CGRect(x: 28, y: 350, width: 16, height: 16))
        // Rows past the bottom stay inside the view.
        #expect(frame.rect(column: 0, row: 100, widthCells: 0).minY == 0)
        #expect(CopyModeCursorFrame(cellWidth: 0, cellHeight: 16, paddingLeft: 0, paddingTop: 0, viewHeight: 1) == nil)
        #expect(CopyModeCursorFrame(cellWidth: .nan, cellHeight: 16, paddingLeft: 0, paddingTop: 0, viewHeight: 1) == nil)
    }
}
