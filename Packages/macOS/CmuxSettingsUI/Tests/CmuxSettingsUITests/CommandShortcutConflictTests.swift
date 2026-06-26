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
        configuredActionShortcuts: [(label: String, shortcut: StoredShortcut)] = [],
        commandShortcuts: [String: StoredShortcut] = [:],
        title: @escaping (String) -> String = { $0 }
    ) -> CommandShortcutConflictChecker {
        CommandShortcutConflictChecker(
            actionBindings: actionBindings,
            configuredActionShortcuts: configuredActionShortcuts,
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

    @Test func conflictsWithConfiguredAction() {
        // A user cmux.json action that already owns ⌘⌥⌃Y must block a command on
        // the same keystroke (the key router runs configured actions first).
        let existing = single("y", command: true, option: true, control: true)
        let label = checker(
            configuredActionShortcuts: [(label: "Run tests", shortcut: existing)]
        ).conflictLabel(
            stroke: single("y", command: true, option: true, control: true),
            excludingCommandId: nil
        )
        #expect(label == "Run tests")
    }

    @Test func conflictsWithConfiguredActionDespiteDuplicateTitles() {
        // Two configured actions share a title but bind different keys; the list
        // (not a title-keyed map) must keep both so neither shortcut is hidden.
        let label = checker(
            configuredActionShortcuts: [
                (label: "Custom", shortcut: single("j", command: true, option: true, control: true)),
                (label: "Custom", shortcut: single("k", command: true, option: true, control: true)),
            ]
        ).conflictLabel(
            stroke: single("k", command: true, option: true, control: true),
            excludingCommandId: nil
        )
        #expect(label == "Custom")
    }

    @Test func conflictsWithConfiguredActionChordPrefix() {
        // A configured chord ⌃B,N: binding a command to its ⌃B prefix would arm
        // the chord and swallow the key, so it must conflict.
        let chord = StoredShortcut(
            first: ShortcutStroke(key: "b", control: true),
            second: ShortcutStroke(key: "n")
        )
        let label = checker(
            configuredActionShortcuts: [(label: "Chord action", shortcut: chord)]
        ).conflictLabel(
            stroke: single("b", control: true),
            excludingCommandId: nil
        )
        #expect(label == "Chord action")
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
