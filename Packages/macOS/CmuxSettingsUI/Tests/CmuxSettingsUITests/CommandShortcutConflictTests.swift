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

    private func checker(
        actionBindings: [String: StoredShortcut] = [:],
        commandShortcuts: [String: StoredShortcut] = [:],
        title: @escaping (String) -> String = { $0 }
    ) -> CommandShortcutConflictChecker {
        CommandShortcutConflictChecker(
            actionBindings: actionBindings,
            commandShortcuts: commandShortcuts,
            title: title
        )
    }

    @Test func freeKeystrokeHasNoConflict() {
        let label = checker().conflictLabel(
            stroke: single("y", command: true, option: true, control: true),
            excludingCommandId: nil
        )
        #expect(label == nil)
    }

    @Test func conflictsWithAnotherCommand() {
        let existing = single("y", command: true, option: true, control: true)
        let label = checker(
            commandShortcuts: ["palette.foo": existing],
            title: { $0 == "palette.foo" ? "Foo" : $0 }
        ).conflictLabel(
            stroke: single("y", command: true, option: true, control: true),
            excludingCommandId: nil
        )
        #expect(label == "Foo")
    }

    @Test func rebindingExcludesItself() {
        // Re-recording the same command's shortcut must not flag the command's
        // own existing binding as a conflict.
        let existing = single("y", command: true, option: true, control: true)
        let label = checker(commandShortcuts: ["palette.foo": existing]).conflictLabel(
            stroke: single("y", command: true, option: true, control: true),
            excludingCommandId: "palette.foo"
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
        let label = checker().conflictLabel(
            stroke: StoredShortcut(first: def.first),
            excludingCommandId: nil
        )
        #expect(label != nil)
    }

    @Test func conflictsWithOverriddenBuiltInAction() {
        // The conflict check honors a user's `shortcuts.bindings` override, not
        // just the built-in default. ⌘⌥⌃J is not any built-in default, so a
        // non-nil result here can only come from honoring the override binding.
        let action = ShortcutAction.commandPalette
        let override = single("j", command: true, option: true, control: true)
        let label = checker(actionBindings: [action.rawValue: override]).conflictLabel(
            stroke: single("j", command: true, option: true, control: true),
            excludingCommandId: nil
        )
        #expect(label != nil)
    }
}
