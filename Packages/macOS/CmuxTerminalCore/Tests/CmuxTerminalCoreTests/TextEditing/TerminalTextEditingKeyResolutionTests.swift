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
        let cases: [(keyCode: UInt16, bytes: [UInt8])] = [
            (Key.leftArrow, [0x01]),      // Ctrl+A
            (Key.rightArrow, [0x05]),     // Ctrl+E
            (Key.backspace, [0x15]),      // Ctrl+U
            (Key.forwardDelete, [0x0B]),  // Ctrl+K
        ]
        for testCase in cases {
            let action = terminalTextEditingResolve(keyCode: testCase.keyCode, modifiers: [.command])
            #expect(action?.bytes == testCase.bytes, "keyCode \(testCase.keyCode)")
        }
    }

    @Test func optionGesturesResolveToWordWiseEditing() {
        let cases: [(keyCode: UInt16, bytes: [UInt8])] = [
            (Key.leftArrow, [0x1B, 0x62]),      // Alt+b
            (Key.rightArrow, [0x1B, 0x66]),     // Alt+f
            (Key.backspace, [0x17]),            // Ctrl+W
            (Key.forwardDelete, [0x1B, 0x64]),  // Alt+d
        ]
        for testCase in cases {
            let action = terminalTextEditingResolve(keyCode: testCase.keyCode, modifiers: [.option])
            #expect(action?.bytes == testCase.bytes, "keyCode \(testCase.keyCode)")
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
        let action = terminalTextEditingResolve(
            keyCode: Key.leftArrow,
            modifiers: [.option, .capsLock, .numericPad, .function]
        )
        #expect(action?.bytes == [0x1B, 0x62])
    }
}
