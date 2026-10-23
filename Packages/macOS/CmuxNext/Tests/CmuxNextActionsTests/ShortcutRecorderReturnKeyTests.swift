import AppKit
import CmuxNextActions
import Testing

/// The shortcut recorder (palette Cmd-K and Settings > Keyboard) answers a
/// pending prompt with bare Return / Option-Return only. Every other Return
/// chord is a chord to record: Cmd-Return must be recordable, and
/// Shift-Return while a conflict prompt is open must not replace the other
/// action's key without asking.
@MainActor @Suite struct ShortcutRecorderReturnKeyTests {
    final class Editor: ShortcutRecorderEditing {
        var saved: [[ShortcutChange]] = []
        func environment(for event: NSEvent?) -> ShortcutEditEnvironment { ShortcutEditEnvironment() }
        func save(_ changes: [ShortcutChange]) { saved.append(changes) }
        func restoreDefault(_ id: ActionID, unbinding others: [ActionID]) {}
    }

    final class Harness {
        let registry = ActionRegistry.standard()
        let editor = Editor()
        var state: ShortcutRecorderState?
        lazy var recorder: ShortcutRecorder = {
            let recorder = ShortcutRecorder(registry: registry, state: { [unowned self] in state },
                                            setState: { [unowned self] in state = $0 }, didFinish: { _, _ in })
            recorder.editor = editor
            return recorder
        }()
    }

    static let returnKeyCode: UInt16 = 36

    @Test func commandReturnIsRecordedWhenNothingIsPending() throws {
        let harness = Harness()
        #expect(harness.recorder.begin("about"))
        let commandReturn = Shortcut(Shortcut.returnKey, modifiers: [.command])
        harness.recorder.handle(commandReturn, keyCode: Self.returnKeyCode)
        // Recorded: either saved at once or held in a prompt, never dropped.
        let savedIt = harness.editor.saved.contains { $0.contains(ShortcutChange("about", commandReturn)) }
        #expect(savedIt || harness.state?.recorded == commandReturn,
                "Cmd-Return was swallowed: state \(String(describing: harness.state)), saved \(harness.editor.saved)")
    }

    @Test func shiftReturnDuringAConflictPromptDoesNotReplaceTheOtherKey() throws {
        let harness = Harness()
        let owner: ActionID = "closeOtherTabsInPane"
        let taken = try #require(harness.registry.effectiveShortcut(for: owner))
        #expect(harness.recorder.begin("about"))
        harness.recorder.handle(taken, keyCode: 17)
        try #require(harness.state?.pending != nil, "recording \(taken.displayString) should ask about \(owner)")

        harness.recorder.handle(Shortcut(Shortcut.returnKey, modifiers: [.shift]), keyCode: Self.returnKeyCode)
        #expect(harness.editor.saved.isEmpty, "Shift-Return saved \(harness.editor.saved) without the prompt's answer")
        #expect(harness.registry.effectiveShortcut(for: owner) == taken)
    }

    @Test func bareReturnStillAnswersAPendingPrompt() throws {
        let harness = Harness()
        let owner: ActionID = "closeOtherTabsInPane"
        let taken = try #require(harness.registry.effectiveShortcut(for: owner))
        #expect(harness.recorder.begin("about"))
        harness.recorder.handle(taken, keyCode: 17)
        try #require(harness.state?.pending != nil)

        harness.recorder.handle(Shortcut(Shortcut.returnKey, modifiers: []), keyCode: Self.returnKeyCode)
        #expect(harness.editor.saved.count == 1)
        #expect(harness.state == nil)
    }
}
