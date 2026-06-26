import Testing
import CmuxSettings
@testable import CmuxSettingsUI

@MainActor
@Suite("Custom command shortcut conflict detection")
struct CommandShortcutConflictTests {
    private func single(
        _ key: String,
        command: Bool = false,
        shift: Bool = false,
        option: Bool = false,
        control: Bool = false
    ) -> StoredShortcut {
        StoredShortcut(first: ShortcutStroke(
            key: key,
            command: command,
            shift: shift,
            option: option,
            control: control
        ))
    }

    @Test func freeKeystrokeHasNoConflict() {
        let label = commandShortcutConflictLabel(
            stroke: single("y", command: true, option: true, control: true),
            excludingCommandId: nil,
            actionBindings: [:],
            commandShortcuts: [:],
            title: { $0 }
        )
        #expect(label == nil)
    }

    @Test func conflictsWithAnotherCommand() {
        let existing = single("y", command: true, option: true, control: true)
        let label = commandShortcutConflictLabel(
            stroke: single("y", command: true, option: true, control: true),
            excludingCommandId: nil,
            actionBindings: [:],
            commandShortcuts: ["palette.foo": existing],
            title: { $0 == "palette.foo" ? "Foo" : $0 }
        )
        #expect(label == "Foo")
    }

    @Test func rebindingExcludesItself() {
        // Re-recording the same command's shortcut must not flag the command's
        // own existing binding as a conflict.
        let existing = single("y", command: true, option: true, control: true)
        let label = commandShortcutConflictLabel(
            stroke: single("y", command: true, option: true, control: true),
            excludingCommandId: "palette.foo",
            actionBindings: [:],
            commandShortcuts: ["palette.foo": existing],
            title: { $0 }
        )
        #expect(label == nil)
    }

    @Test func conflictsWithBuiltInActionDefault() {
        // A stroke equal to a built-in action's default binding must be blocked
        // so a custom command shortcut can never silently shadow a built-in.
        let action = ShortcutAction.commandPalette
        guard let def = action.defaultShortcut, !def.isUnbound else {
            Issue.record("commandPalette is expected to have a default binding")
            return
        }
        let label = commandShortcutConflictLabel(
            stroke: StoredShortcut(first: def.first),
            excludingCommandId: nil,
            actionBindings: [:],
            commandShortcuts: [:],
            title: { $0 }
        )
        #expect(label != nil)
    }

    @Test func conflictsWithOverriddenBuiltInAction() {
        // The conflict check honors a user's `shortcuts.bindings` override, not
        // just the built-in default.
        let action = ShortcutAction.commandPalette
        let override = single("j", command: true, option: true, control: true)
        // ⌘⌥⌃J is not any built-in default, so a non-nil result here can only
        // come from honoring the override binding.
        let label = commandShortcutConflictLabel(
            stroke: single("j", command: true, option: true, control: true),
            excludingCommandId: nil,
            actionBindings: [action.rawValue: override],
            commandShortcuts: [:],
            title: { $0 }
        )
        #expect(label != nil)
    }
}
