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
    }

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
}
