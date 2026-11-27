import CmuxTerminalCore
import Testing

@Suite("Terminal text-editing gesture resolver")
struct TerminalTextEditingKeyResolutionTests {
    private enum Key {
        static let backspace: UInt16 = 0x33
        static let forwardDelete: UInt16 = 0x75
        static let leftArrow: UInt16 = 0x7B
        static let rightArrow: UInt16 = 0x7C
        static let letterC: UInt16 = 0x08
        static let letterW: UInt16 = 0x0D
        static let upArrow: UInt16 = 0x7E
    }

    private static let lineWise: [(keyCode: UInt16, chord: TerminalTextEditingChord)] = [
        (Key.leftArrow, TerminalTextEditingChord(letter: "a", modifier: .control)),
        (Key.rightArrow, TerminalTextEditingChord(letter: "e", modifier: .control)),
        (Key.backspace, TerminalTextEditingChord(letter: "u", modifier: .control)),
        (Key.forwardDelete, TerminalTextEditingChord(letter: "k", modifier: .control)),
    ]

    private static let wordWise: [(keyCode: UInt16, chord: TerminalTextEditingChord)] = [
        (Key.leftArrow, TerminalTextEditingChord(letter: "b", modifier: .option)),
        (Key.rightArrow, TerminalTextEditingChord(letter: "f", modifier: .option)),
        (Key.backspace, TerminalTextEditingChord(letter: "w", modifier: .control)),
        (Key.forwardDelete, TerminalTextEditingChord(letter: "d", modifier: .option)),
    ]

    @Test func commandGesturesResolveToLineWiseEditing() {
        let cases: [(keyCode: UInt16, chord: TerminalTextEditingChord)] = [
            (Key.leftArrow, TerminalTextEditingChord(letter: "a", modifier: .control)),
            (Key.rightArrow, TerminalTextEditingChord(letter: "e", modifier: .control)),
            (Key.backspace, TerminalTextEditingChord(letter: "u", modifier: .control)),
            (Key.forwardDelete, TerminalTextEditingChord(letter: "k", modifier: .control)),
        ]
        for testCase in cases {
            let chord = terminalTextEditingResolve(keyCode: testCase.keyCode, modifiers: [.command])
            #expect(chord == testCase.chord, "keyCode \(testCase.keyCode)")
        }
    }

    @Test func optionGesturesResolveToWordWiseEditing() {
        let cases: [(keyCode: UInt16, chord: TerminalTextEditingChord)] = [
            (Key.leftArrow, TerminalTextEditingChord(letter: "b", modifier: .option)),
            (Key.rightArrow, TerminalTextEditingChord(letter: "f", modifier: .option)),
            (Key.backspace, TerminalTextEditingChord(letter: "w", modifier: .control)),
            (Key.forwardDelete, TerminalTextEditingChord(letter: "d", modifier: .option)),
        ]
        for testCase in cases {
            let chord = terminalTextEditingResolve(keyCode: testCase.keyCode, modifiers: [.option])
            #expect(chord == testCase.chord, "keyCode \(testCase.keyCode)")
        }
    }

    /// Control must always reach the remote, or the mode would eat Ctrl+C.
    @Test func controlBearingEventsAlwaysPassThrough() {
        let modifierSets: [TerminalTextEditingModifiers] = [
            [.control],
            [.control, .command],
            [.control, .option],
            [.control, .shift],
        ]
        for modifiers in modifierSets {
            #expect(terminalTextEditingResolve(keyCode: Key.letterC, modifiers: modifiers) == nil)
            #expect(terminalTextEditingResolve(keyCode: Key.leftArrow, modifiers: modifiers) == nil)
        }
    }

    /// Readline and zle have no selection model, so shift has nothing to target.
    @Test func shiftExtendedGesturesPassThrough() {
        #expect(terminalTextEditingResolve(keyCode: Key.leftArrow, modifiers: [.command, .shift]) == nil)
        #expect(terminalTextEditingResolve(keyCode: Key.rightArrow, modifiers: [.option, .shift]) == nil)
    }

    /// Command+Option is ambiguous; neither family should claim it.
    @Test func commandAndOptionTogetherPassThrough() {
        #expect(terminalTextEditingResolve(keyCode: Key.leftArrow, modifiers: [.command, .option]) == nil)
    }

    /// An unmodified keystroke is ordinary input, not a gesture.
    @Test func unmodifiedKeysPassThrough() {
        #expect(terminalTextEditingResolve(keyCode: Key.leftArrow, modifiers: []) == nil)
        #expect(terminalTextEditingResolve(keyCode: Key.backspace, modifiers: []) == nil)
    }

    /// Only the four navigation/deletion keys are owned; Cmd+C must stay a shortcut.
    @Test func unmappedKeysPassThroughEvenWithGestureModifiers() {
        #expect(terminalTextEditingResolve(keyCode: Key.letterC, modifiers: [.command]) == nil)
        #expect(terminalTextEditingResolve(keyCode: Key.letterC, modifiers: [.option]) == nil)
    }

    /// Lock and pad modifiers are noise and must not defeat a real gesture.
    @Test func ignoredModifiersDoNotBlockResolution() {
        let chord = terminalTextEditingResolve(
            keyCode: Key.leftArrow,
            modifiers: [.option, .capsLock, .numericPad, .function]
        )
        #expect(chord == TerminalTextEditingChord(letter: "b", modifier: .option))
    }

    // MARK: - Browser-style layout (Command moves by word)

    @Test func commandMovesByWordLayoutMapsCommandToWordWiseEditing() {
        for testCase in Self.wordWise {
            let chord = terminalTextEditingResolve(
                keyCode: testCase.keyCode,
                modifiers: [.command],
                layout: .commandMovesByWord
            )
            #expect(chord == testCase.chord, "keyCode \(testCase.keyCode)")
        }
    }

    @Test func commandMovesByWordLayoutKeepsOptionWordWise() {
        for testCase in Self.wordWise {
            let chord = terminalTextEditingResolve(
                keyCode: testCase.keyCode,
                modifiers: [.option],
                layout: .commandMovesByWord
            )
            #expect(chord == testCase.chord, "keyCode \(testCase.keyCode)")
        }
    }

    @Test func commandMovesByWordLayoutMapsControlArrowsToLineStartAndEnd() {
        #expect(
            terminalTextEditingResolve(keyCode: Key.leftArrow, modifiers: [.control], layout: .commandMovesByWord)
                == TerminalTextEditingChord(letter: "a", modifier: .control)
        )
        #expect(
            terminalTextEditingResolve(keyCode: Key.rightArrow, modifiers: [.control], layout: .commandMovesByWord)
                == TerminalTextEditingChord(letter: "e", modifier: .control)
        )
    }

    /// Only the two bare Control arrows are claimed; Ctrl+W, Ctrl+C and the
    /// Control delete keys keep their shell meaning in every layout.
    @Test func commandMovesByWordLayoutLeavesEveryOtherControlChordAlone() {
        let keyCodes = [Key.letterC, Key.letterW, Key.backspace, Key.forwardDelete, Key.upArrow]
        for keyCode in keyCodes {
            #expect(
                terminalTextEditingResolve(keyCode: keyCode, modifiers: [.control], layout: .commandMovesByWord) == nil,
                "keyCode \(keyCode)"
            )
        }
        let modifierSets: [TerminalTextEditingModifiers] = [
            [.control, .shift],
            [.control, .option],
            [.control, .command],
        ]
        for modifiers in modifierSets {
            #expect(terminalTextEditingResolve(keyCode: Key.leftArrow, modifiers: modifiers, layout: .commandMovesByWord) == nil)
            #expect(terminalTextEditingResolve(keyCode: Key.rightArrow, modifiers: modifiers, layout: .commandMovesByWord) == nil)
        }
    }

    @Test func standardLayoutNeverClaimsControlArrows() {
        #expect(terminalTextEditingResolve(keyCode: Key.leftArrow, modifiers: [.control], layout: .standard) == nil)
        #expect(terminalTextEditingResolve(keyCode: Key.rightArrow, modifiers: [.control], layout: .standard) == nil)
    }

    @Test func standardLayoutIsTheDefault() {
        for testCase in Self.lineWise {
            #expect(
                terminalTextEditingResolve(keyCode: testCase.keyCode, modifiers: [.command], layout: .standard)
                    == terminalTextEditingResolve(keyCode: testCase.keyCode, modifiers: [.command])
            )
            #expect(
                terminalTextEditingResolve(keyCode: testCase.keyCode, modifiers: [.command], layout: .standard)
                    == testCase.chord
            )
        }
    }

    @Test func commandMovesByWordLayoutPassesShiftAndAmbiguousChordsThrough() {
        #expect(terminalTextEditingResolve(keyCode: Key.leftArrow, modifiers: [.command, .shift], layout: .commandMovesByWord) == nil)
        #expect(terminalTextEditingResolve(keyCode: Key.leftArrow, modifiers: [.command, .option], layout: .commandMovesByWord) == nil)
        #expect(terminalTextEditingResolve(keyCode: Key.leftArrow, modifiers: [], layout: .commandMovesByWord) == nil)
        #expect(terminalTextEditingResolve(keyCode: Key.letterC, modifiers: [.command], layout: .commandMovesByWord) == nil)
    }

    @Test func commandMovesByWordLayoutIgnoresLockAndPadModifiersOnControlArrows() {
        // Arrow keys carry the function and numeric-pad flags on real hardware.
        let chord = terminalTextEditingResolve(
            keyCode: Key.leftArrow,
            modifiers: [.control, .function, .numericPad, .capsLock],
            layout: .commandMovesByWord
        )
        #expect(chord == TerminalTextEditingChord(letter: "a", modifier: .control))
    }

    // MARK: - Candidate pre-filter

    /// The pre-filter is the union of both layouts, so it must accept every
    /// gesture either layout resolves and reject everything neither does.
    @Test func gestureCandidateIsTheUnionOfEveryLayout() {
        let keyCodes = [Key.leftArrow, Key.rightArrow, Key.upArrow, Key.backspace, Key.forwardDelete, Key.letterC, Key.letterW]
        let modifierSets: [TerminalTextEditingModifiers] = [
            [], [.command], [.option], [.control], [.shift],
            [.command, .shift], [.option, .shift], [.control, .shift],
            [.command, .option], [.control, .option], [.control, .command],
        ]
        for keyCode in keyCodes {
            for modifiers in modifierSets {
                let expected = terminalTextEditingResolve(keyCode: keyCode, modifiers: modifiers, layout: .standard) != nil
                    || terminalTextEditingResolve(keyCode: keyCode, modifiers: modifiers, layout: .commandMovesByWord) != nil
                #expect(
                    terminalTextEditingIsGestureCandidate(keyCode: keyCode, modifiers: modifiers) == expected,
                    "keyCode \(keyCode) modifiers \(modifiers.rawValue)"
                )
            }
        }
        #expect(terminalTextEditingIsGestureCandidate(keyCode: Key.leftArrow, modifiers: [.control]))
        #expect(!terminalTextEditingIsGestureCandidate(keyCode: Key.letterW, modifiers: [.control]))
        #expect(!terminalTextEditingIsGestureCandidate(keyCode: Key.leftArrow, modifiers: []))
    }
}
