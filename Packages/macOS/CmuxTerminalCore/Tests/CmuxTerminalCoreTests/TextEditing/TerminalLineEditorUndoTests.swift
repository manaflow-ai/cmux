import CmuxTerminalCore
import Testing

@Suite("Terminal line-editor undo")
struct TerminalLineEditorUndoTests {
    @Test func commandZAtAPromptReplaysLineEditorUndo() {
        #expect(TerminalLineEditorUndo(
            isUndoChord: true,
            hasGhosttyBinding: false,
            isComposing: false,
            keyboardCopyModeActive: false
        ).shouldReplay(isAlternateScreenActive: { false }))
    }

    @Test func fullScreenApplicationsKeepTheOriginalKeystroke() {
        #expect(!TerminalLineEditorUndo(
            isUndoChord: true,
            hasGhosttyBinding: false,
            isComposing: false,
            keyboardCopyModeActive: false
        ).shouldReplay(isAlternateScreenActive: { true }))
    }

    @Test func anUnreadableScreenKeepsTheOriginalKeystroke() {
        #expect(!TerminalLineEditorUndo(
            isUndoChord: true,
            hasGhosttyBinding: false,
            isComposing: false,
            keyboardCopyModeActive: false
        ).shouldReplay(isAlternateScreenActive: { nil }))
    }

    struct OtherOwner: Sendable, CustomTestStringConvertible {
        var isUndoChord = true
        var hasGhosttyBinding = false
        var isComposing = false
        var keyboardCopyModeActive = false
        let testDescription: String
    }

    @Test(arguments: [
        OtherOwner(isUndoChord: false, testDescription: "not Cmd+Z"),
        OtherOwner(hasGhosttyBinding: true, testDescription: "user Ghostty binding"),
        OtherOwner(isComposing: true, testDescription: "input method composing"),
        OtherOwner(keyboardCopyModeActive: true, testDescription: "keyboard copy mode"),
    ])
    func otherOwnersOfTheKeystrokeWinWithoutReadingTheScreen(owner: OtherOwner) {
        var readScreen = false
        #expect(!TerminalLineEditorUndo(
            isUndoChord: owner.isUndoChord,
            hasGhosttyBinding: owner.hasGhosttyBinding,
            isComposing: owner.isComposing,
            keyboardCopyModeActive: owner.keyboardCopyModeActive
        ).shouldReplay(isAlternateScreenActive: { readScreen = true; return false }))
        #expect(!readScreen)
    }
}
