import Testing
@testable import CmuxSettings

/// Covers the package-side constraints that keep the Settings recorder from
/// persisting a system-wide (global) hotkey binding the runtime cannot
/// register. Mirrors the app target's `normalizedSystemWideHotkeyShortcutResult`
/// gate: system-wide actions accept only single strokes carrying a primary
/// modifier (Command/Option/Control), never a chord and never Shift-only.
@Suite("System-wide hotkey shortcut constraints")
struct SystemWideHotkeyShortcutActionTests {
    /// The exact set the runtime registers as system-wide Carbon hotkeys.
    private let systemWideActions: Set<ShortcutAction> = [
        .showHideAllWindows,
        .globalSearch,
        .sendAppshot,
    ]

    @Test func isSystemWideHotkeyMatchesTheCarbonRegisteredSet() {
        for action in ShortcutAction.allCases {
            #expect(
                action.isSystemWideHotkey == systemWideActions.contains(action),
                "\(action) isSystemWideHotkey should match the system-wide Carbon hotkey set"
            )
        }
    }

    @Test func systemWideHotkeyActionsDisallowChords() {
        for action in ShortcutAction.allCases where action.isSystemWideHotkey {
            #expect(
                !action.allowsChordShortcut,
                "\(action) is a system-wide hotkey and must not allow a two-stroke chord"
            )
        }
        // The constraint is scoped: a regular action still allows a chord.
        #expect(ShortcutAction.newTab.allowsChordShortcut)
    }

    @Test func primaryModifierExcludesShiftOnly() {
        #expect(ShortcutStroke(key: "a", command: true).hasPrimaryModifier)
        #expect(ShortcutStroke(key: "a", option: true).hasPrimaryModifier)
        #expect(ShortcutStroke(key: "a", control: true).hasPrimaryModifier)
        // Shift alone satisfies `hasAnyModifier` but not the system-wide
        // requirement, so a Shift-only Appshot binding must be rejected.
        #expect(ShortcutStroke(key: "a", shift: true).hasAnyModifier)
        #expect(!ShortcutStroke(key: "a", shift: true).hasPrimaryModifier)
        #expect(!ShortcutStroke(key: "a").hasPrimaryModifier)
    }
}
