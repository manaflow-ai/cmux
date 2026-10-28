import CmuxTerminalCore
import Testing

@Suite("Terminal line-editor undo")
struct TerminalLineEditorUndoTests {
    @Test func commandZAtAPromptReplaysLineEditorUndo() {
        #expect(TerminalLineEditorUndo.shouldReplay(
            isUndoChord: true,
            hasGhosttyBinding: false,
            isComposing: false,
            keyboardCopyModeActive: false,
            isAlternateScreenActive: { false }
        ))
    }

    /// Ctrl+_ is the undo key of readline, zle, fish and agent composers.
    @Test func replayWritesControlUnderscore() {
        #expect(TerminalLineEditorUndo.bindingAction == "text:\\x1f")
    }

    @Test func fullScreenApplicationsKeepTheOriginalKeystroke() {
        #expect(!TerminalLineEditorUndo.shouldReplay(
            isUndoChord: true,
            hasGhosttyBinding: false,
            isComposing: false,
            keyboardCopyModeActive: false,
            isAlternateScreenActive: { true }
        ))
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
        #expect(!TerminalLineEditorUndo.shouldReplay(
            isUndoChord: owner.isUndoChord,
            hasGhosttyBinding: owner.hasGhosttyBinding,
            isComposing: owner.isComposing,
            keyboardCopyModeActive: owner.keyboardCopyModeActive,
            isAlternateScreenActive: { readScreen = true; return false }
        ))
        #expect(!readScreen)
    }
}
