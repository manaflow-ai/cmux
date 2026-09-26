import CmuxTerminalCore
import Testing

@Suite("Terminal prompt selection resolver")
struct TerminalPromptSelectionTests {
    private enum Key {
        static let backspace: UInt16 = 0x33
        static let forwardDelete: UInt16 = 0x75
        static let leftArrow: UInt16 = 0x7B
        static let rightArrow: UInt16 = 0x7C
        static let letterA: UInt16 = 0x00
        static let returnKey: UInt16 = 0x24
    }

    private func snapshot(
        length: Int = 5,
        caret: Int = 5,
        selection: Range<Int>? = nil
    ) -> TerminalPromptInputSnapshot {
        TerminalPromptInputSnapshot(length: length, caret: caret, selection: selection)
    }

    // MARK: Outside a prompt

    /// No prompt state (TUI, alternate screen, running command, no shell
    /// integration) must leave every gesture exactly as it is today.
    @Test func everyIntentPassesThroughWithoutPromptState() {
        let intents: [TerminalPromptSelectionIntent] = [
            .selectAll,
            .extend(.backward, .character),
            .extend(.forward, .inputBoundary),
            .cut,
            .delete,
            .insertText,
        ]
        for intent in intents {
            let tracked = TerminalPromptSelection(anchor: 0, head: 3)
            #expect(
                terminalPromptSelectionResolve(intent: intent, snapshot: nil, tracked: tracked) == .passThrough,
                "\(intent)"
            )
        }
    }

    // MARK: Select all

    @Test func selectAllSelectsTheWholeInput() {
        let action = terminalPromptSelectionResolve(intent: .selectAll, snapshot: snapshot(caret: 2), tracked: nil)
        #expect(action == .select(TerminalPromptSelection(anchor: 0, head: 5)))
    }

    @Test func selectAllOnAnEmptyPromptKeepsTodaysBehavior() {
        let action = terminalPromptSelectionResolve(
            intent: .selectAll,
            snapshot: snapshot(length: 0, caret: 0),
            tracked: nil
        )
        #expect(action == .passThrough)
    }

    // MARK: Extending

    @Test func shiftLeftFromTheCaretSelectsOneStop() {
        let action = terminalPromptSelectionResolve(
            intent: .extend(.backward, .character),
            snapshot: snapshot(caret: 5),
            tracked: nil
        )
        #expect(action == .select(TerminalPromptSelection(anchor: 5, head: 4)))
    }

    @Test func trackedSelectionKeepsItsAnchor() {
        let tracked = TerminalPromptSelection(anchor: 5, head: 3)
        let action = terminalPromptSelectionResolve(
            intent: .extend(.backward, .character),
            snapshot: snapshot(caret: 5, selection: 3..<5),
            tracked: tracked
        )
        #expect(action == .select(TerminalPromptSelection(anchor: 5, head: 2)))
    }

    @Test func extendingBackOntoTheAnchorClearsTheSelection() {
        let tracked = TerminalPromptSelection(anchor: 5, head: 4)
        let action = terminalPromptSelectionResolve(
            intent: .extend(.forward, .character),
            snapshot: snapshot(caret: 5, selection: 4..<5),
            tracked: tracked
        )
        #expect(action == .clearSelection)
    }

    @Test func extendingPastTheInputEdgeIsConsumedWithoutChange() {
        let atStart = terminalPromptSelectionResolve(
            intent: .extend(.backward, .character),
            snapshot: snapshot(caret: 0),
            tracked: nil
        )
        #expect(atStart == .consume)

        let atEnd = terminalPromptSelectionResolve(
            intent: .extend(.forward, .inputBoundary),
            snapshot: snapshot(caret: 5),
            tracked: nil
        )
        #expect(atEnd == .consume)
    }

    @Test func commandShiftExtendsToTheInputBoundary() {
        let backward = terminalPromptSelectionResolve(
            intent: .extend(.backward, .inputBoundary),
            snapshot: snapshot(caret: 3),
            tracked: nil
        )
        #expect(backward == .select(TerminalPromptSelection(anchor: 3, head: 0)))

        let forward = terminalPromptSelectionResolve(
            intent: .extend(.forward, .inputBoundary),
            snapshot: snapshot(caret: 3),
            tracked: nil
        )
        #expect(forward == .select(TerminalPromptSelection(anchor: 3, head: 5)))
    }

    /// A stale tracked selection (the user dragged a new one with the mouse)
    /// must not win over what the terminal actually has selected.
    @Test func staleTrackedSelectionIsIgnored() {
        let stale = TerminalPromptSelection(anchor: 5, head: 4)
        let action = terminalPromptSelectionResolve(
            intent: .extend(.forward, .character),
            snapshot: snapshot(caret: 5, selection: 1..<3),
            tracked: stale
        )
        #expect(action == .select(TerminalPromptSelection(anchor: 1, head: 4)))
    }

    // MARK: Editing a selection

    @Test func deleteMovesToTheSelectionEndThenBackspaces() {
        let action = terminalPromptSelectionResolve(
            intent: .delete,
            snapshot: snapshot(caret: 5, selection: 1..<3),
            tracked: nil
        )
        let edit = TerminalPromptInputEdit(moveLeft: 2, moveRight: 0, deleteBackward: 2)
        #expect(action == .edit(edit, copyFirst: false, thenPassThrough: false))
    }

    @Test func cutCopiesFirstAndTypingPassesTheKeyThrough() {
        let cut = terminalPromptSelectionResolve(
            intent: .cut,
            snapshot: snapshot(caret: 0, selection: 0..<5),
            tracked: nil
        )
        let wholeLine = TerminalPromptInputEdit(moveLeft: 0, moveRight: 5, deleteBackward: 5)
        #expect(cut == .edit(wholeLine, copyFirst: true, thenPassThrough: false))

        let typed = terminalPromptSelectionResolve(
            intent: .insertText,
            snapshot: snapshot(caret: 0, selection: 0..<5),
            tracked: nil
        )
        #expect(typed == .edit(wholeLine, copyFirst: false, thenPassThrough: true))
    }

    /// Cut with nothing selected in the input must not reach the clipboard.
    @Test func editsWithoutAnInputSelectionPassThrough() {
        for intent in [TerminalPromptSelectionIntent.cut, .delete, .insertText] {
            let action = terminalPromptSelectionResolve(intent: intent, snapshot: snapshot(), tracked: nil)
            #expect(action == .passThrough, "\(intent)")
        }
    }

    @Test func editCountsFollowTheCaret() {
        #expect(
            TerminalPromptInputEdit.deleting(2..<4, caret: 4)
                == TerminalPromptInputEdit(moveLeft: 0, moveRight: 0, deleteBackward: 2)
        )
        #expect(
            TerminalPromptInputEdit.deleting(2..<4, caret: 1)
                == TerminalPromptInputEdit(moveLeft: 0, moveRight: 3, deleteBackward: 2)
        )
        #expect(
            TerminalPromptInputEdit.deleting(2..<4, caret: 7)
                == TerminalPromptInputEdit(moveLeft: 3, moveRight: 0, deleteBackward: 2)
        )
    }

    // MARK: Key mapping

    @Test func shiftArrowsMapToExtension() {
        #expect(
            terminalPromptSelectionIntent(keyCode: Key.leftArrow, modifiers: [.shift], producesText: false)
                == .extend(.backward, .character)
        )
        #expect(
            terminalPromptSelectionIntent(keyCode: Key.rightArrow, modifiers: [.shift, .command], producesText: false)
                == .extend(.forward, .inputBoundary)
        )
        // Arrow keys carry the function and numeric-pad flags on macOS.
        #expect(
            terminalPromptSelectionIntent(
                keyCode: Key.rightArrow,
                modifiers: [.shift, .function, .numericPad],
                producesText: false
            ) == .extend(.forward, .character)
        )
    }

    @Test func plainArrowsAndDeletionChordsDoNotMap() {
        #expect(terminalPromptSelectionIntent(keyCode: Key.leftArrow, modifiers: [], producesText: false) == nil)
        #expect(terminalPromptSelectionIntent(keyCode: Key.leftArrow, modifiers: [.command], producesText: false) == nil)
        #expect(terminalPromptSelectionIntent(keyCode: Key.backspace, modifiers: [.command], producesText: false) == nil)
        #expect(terminalPromptSelectionIntent(keyCode: Key.backspace, modifiers: [], producesText: false) == .delete)
        #expect(terminalPromptSelectionIntent(keyCode: Key.forwardDelete, modifiers: [.function], producesText: false) == .delete)
    }

    /// Control and Option stay with the shell; Option word selection is not
    /// supported until the input text is available.
    @Test func controlAndOptionNeverMap() {
        let modifierSets: [TerminalTextEditingModifiers] = [[.control], [.control, .shift], [.option, .shift]]
        for modifiers in modifierSets {
            #expect(terminalPromptSelectionIntent(keyCode: Key.leftArrow, modifiers: modifiers, producesText: false) == nil)
            #expect(terminalPromptSelectionIntent(keyCode: Key.letterA, modifiers: modifiers, producesText: true) == nil)
        }
    }

    @Test func printableTextMapsToInsertion() {
        #expect(terminalPromptSelectionIntent(keyCode: Key.letterA, modifiers: [], producesText: true) == .insertText)
        #expect(terminalPromptSelectionIntent(keyCode: Key.letterA, modifiers: [.shift], producesText: true) == .insertText)
        #expect(terminalPromptSelectionIntent(keyCode: Key.letterA, modifiers: [.command], producesText: true) == nil)
        #expect(terminalPromptSelectionIntent(keyCode: Key.returnKey, modifiers: [], producesText: false) == nil)
    }
}
