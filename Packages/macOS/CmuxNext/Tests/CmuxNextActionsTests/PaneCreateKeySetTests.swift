import AppKit
import CmuxNextActions
import Foundation
import Testing

/// The pane-creating keys are one pattern (key set A, 2026-11-01). Ghostty's Cmd-D / Shift-Cmd-D
/// split the focused pane right / down and stay. cmux's own create keys use the key beside D, X, as a
/// second D: Ctrl adds a new column / row, Option adds a browser, and Shift means "below" every
/// time. The old keys sat on D, where macOS keeps Ctrl-Cmd-D (Look Up) and Opt-Cmd-D (Dock hiding).
@MainActor @Suite struct PaneCreateKeySetTests {
    nonisolated static let set: [(action: String, key: String)] = [
        ("newColumn", "ctrl+cmd+x"), ("newRow", "ctrl+shift+cmd+x"),
        ("splitBrowserRight", "opt+cmd+x"), ("splitBrowserDown", "opt+shift+cmd+x"),
    ]

    /// Each "below" key is its "right" key plus Shift, as Cmd-D / Shift-Cmd-D.
    @Test func shiftMeansBelowInEveryPair() throws {
        let registry = ActionRegistry.standard()
        for (right, below) in [("splitRight", "splitDown"), ("newColumn", "newRow"), ("splitBrowserRight", "splitBrowserDown")] {
            let r = try #require(registry.descriptor(for: ActionID(rawValue: right))?.defaultShortcut, "\(right)")
            let b = try #require(registry.descriptor(for: ActionID(rawValue: below))?.defaultShortcut, "\(below)")
            #expect(b == Shortcut(r.key, modifiers: r.modifiers.union(.shift)), "\(below) is not \(right) plus Shift")
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
}
