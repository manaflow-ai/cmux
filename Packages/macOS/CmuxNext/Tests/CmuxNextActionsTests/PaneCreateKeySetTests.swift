import AppKit
import CmuxNextActions
import Foundation
import Testing

/// The pane-creating keys are one pattern (key set B, 2026-11-01). Ghostty's Cmd-D / Shift-Cmd-D
/// split the focused pane right / down and stay. cmux's own layout keys follow its focus keys:
/// Ctrl-Cmd-L / Ctrl-Cmd-J move the focus right / down, and the same keys with Option make a new
/// column (right) or row (down) there; Opt-Cmd-L opens a browser to the right. (Not Shift:
/// Ctrl-Shift-Cmd-J is Ghostty's default write_screen_file:copy, which cmux keeps.) The old keys sat on
/// D, where macOS keeps Ctrl-Cmd-D (Look Up) and Opt-Cmd-D (Dock hiding).
@MainActor @Suite struct PaneCreateKeySetTests {
    nonisolated static let set: [(action: String, key: String)] = [
        ("newColumn", "ctrl+opt+cmd+l"), ("newRow", "ctrl+opt+cmd+j"), ("splitBrowserRight", "opt+cmd+l"),
    ]

    /// New Column and New Row are the focus-right / focus-down keys plus Option.
    @Test func createKeysAreTheFocusKeysPlusOption() throws {
        let registry = ActionRegistry.standard()
        let table = RegistryKeyBindings(registry).table
        for (focus, create) in [("focusRight", "newColumn"), ("focusDown", "newRow")] {
            let focusKey = try #require(table.entries.first { $0.command.rawValue == focus && $0.keys.count == 1 && $0.keys[0].modifiers == [.control, .command] }?.keys[0], "\(focus)")
            let createKey = try #require(registry.descriptor(for: ActionID(rawValue: create))?.defaultShortcut, "\(create)")
            #expect(createKey == Shortcut(focusKey.key, modifiers: focusKey.modifiers.union(.option)), "\(create) is not \(focus) plus Option")
        }
    }

    /// Each key of the set is its action's default and runs it in every pane focus the
    /// Ghostty-reserved list checks.
    @Test func eachKeyRunsItsActionInEveryPane() throws {
        let registry = ActionRegistry.standard()
        let table = RegistryKeyBindings(registry).table
        for (action, text) in Self.set {
            let key = try MacOSSystemShortcutsTests.shortcut(text)
            #expect(registry.descriptor(for: ActionID(rawValue: action))?.defaultShortcut == key, "\(action) is not \(text)")
            for context in GhosttyReservedKeysTests.contexts {
                let winner = table.resolve([key], in: KeyContext(context.values), isRunnable: { _ in true }).winner
                #expect(winner?.command.rawValue == action, "\(text) in \(context.name) runs \(winner?.command.rawValue ?? "nothing"), not \(action)")
            }
        }
    }

    /// No key of the set is Ghostty-reserved or a macOS shortcut that is on by default.
    @Test func noKeyOfTheSetIsReserved() throws {
        let reserved = try Set(GhosttyReservedKeysTests.reserved.map { try GhosttyReservedKeysTests.shortcut($0.key) })
        let macOS = try MacOSSystemShortcutsTests.taken()
        for (action, text) in Self.set {
            let key = try MacOSSystemShortcutsTests.shortcut(text)
            #expect(!reserved.contains(key), "\(action) = \(text) is Ghostty-reserved")
            #expect(macOS[key] == nil, "\(action) = \(text) is macOS's \(macOS[key]?.name ?? "")")
        }
    }

    /// Ghostty's own macOS defaults on the set's letters stay Ghostty's: Ctrl-Shift-Cmd-J is
    /// write_screen_file:copy, so New Row is not on it, and no default cmux key takes it.
    @Test func ghosttysScreenFileKeyStaysGhosttys() throws {
        let key = try MacOSSystemShortcutsTests.shortcut("ctrl+shift+cmd+j")
        let entries = RegistryKeyBindings(ActionRegistry.standard()).table.entries.filter { $0.keys == [key] }
        #expect(!entries.contains { Self.set.map(\.action).contains($0.command.rawValue) }, "a key-set action took Ghostty's Ctrl-Shift-Cmd-J")
    }
}
