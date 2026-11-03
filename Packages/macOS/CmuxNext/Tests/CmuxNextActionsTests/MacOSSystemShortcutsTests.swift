import AppKit
import CmuxNextActions
import Foundation
import Testing

/// No default cmux key is a macOS system shortcut that is on by default. macOS takes such a key
/// before cmux sees it, so for a person with default settings the action never runs. Found by the
/// real-key gate (2026-10-31): a real Ctrl-Cmd-D opened Look Up (system hot key 70, on by
/// default) and New Column never ran. Synthetic keys passed, because they skip the window server.
///
/// Sources for ``onByDefault`` (read 2026-10-31):
/// - Apple, "Mac keyboard shortcuts", https://support.apple.com/en-us/102650: Control-Command-D
///   "Show or hide the definition of the selected word", Option-Command-D "Show or hide the
///   Dock", Control-Command-Q lock screen, Control-Command-Space Character Viewer,
///   Option-Command-Esc Force Quit, Command-Space Spotlight, Shift-Command-3 / 4 / 5 screenshots,
///   Shift-Command-Q and Option-Shift-Command-Q log out.
/// - The System Settings > Keyboard > Keyboard Shortcuts defaults of macOS 14.8, 15.7, 26.7 and 27.0
///   (14 and 15 read from the matrix's Tart base images):
///   `/System/Library/ExtensionKit/Extensions/KeyboardSettings.appex/Contents/Resources/en.lproj/DefaultShortcutsTable.xml`
///   (each row's `sybmolichotkey` id; rows with `enabled = false` are off by default and not here).
/// - The window server's own table (`CGSGetSymbolicHotKeyValue`, `CGSIsSymbolicHotKeyEnabled`) on
///   fleet Macs with macOS 26.5, 26.7 and 27.0. None of them overrides these ids in
///   `com.apple.symbolichotkeys`, so the state read is the macOS default.
///
/// Function-key and Globe (fn) shortcuts are not listed: ``Shortcut`` does not carry fn, and no
/// default cmux key uses a function key.
@MainActor @Suite struct MacOSSystemShortcutsTests {
    struct SystemShortcut: Sendable, CustomTestStringConvertible {
        /// keybindings.json syntax.
        let key: String
        /// The `AppleSymbolicHotKeys` id, or nil for an Apple menu key.
        let hotKeyID: Int?
        let name: String
        var testDescription: String { "\(key) (\(name))" }
    }

    /// The macOS shortcuts that are on by default on macOS 14, 15, 26 or 27 (the union).
    nonisolated static let onByDefault: [SystemShortcut] = [
        SystemShortcut(key: "ctrl+cmd+d", hotKeyID: 70, name: "Look Up (definition of the selected word)"),
        SystemShortcut(key: "opt+cmd+d", hotKeyID: 52, name: "Turn Dock hiding on or off"),
        SystemShortcut(key: "cmd+space", hotKeyID: 64, name: "Show Spotlight search"),
        SystemShortcut(key: "opt+cmd+space", hotKeyID: 65, name: "Show Finder search window"),
        SystemShortcut(key: "ctrl+cmd+space", hotKeyID: 50, name: "Emoji & Symbols"),
        SystemShortcut(key: "ctrl+space", hotKeyID: 60, name: "Select the previous input source"),
        SystemShortcut(key: "ctrl+opt+space", hotKeyID: 61, name: "Select next source in Input menu"),
        SystemShortcut(key: "cmd+tab", hotKeyID: 1, name: "App Switcher"),
        SystemShortcut(key: "shift+cmd+tab", hotKeyID: 2, name: "App Switcher, backward"),
        SystemShortcut(key: "cmd+`", hotKeyID: 27, name: "Move focus to next window"),
        SystemShortcut(key: "shift+cmd+`", hotKeyID: 220, name: "Move focus to previous window"),
        SystemShortcut(key: "opt+cmd+`", hotKeyID: 51, name: "Move focus to the window drawer"),
        SystemShortcut(key: "opt+cmd+escape", hotKeyID: 0, name: "Force Quit"),
        SystemShortcut(key: "opt+shift+cmd+escape", hotKeyID: 6, name: "Force Quit the front app"),
        SystemShortcut(key: "cmd+escape", hotKeyID: 260, name: "Game Overlay"),
        SystemShortcut(key: "cmd+m", hotKeyID: 233, name: "Minimize"),
        SystemShortcut(key: "ctrl+up", hotKeyID: 32, name: "Mission Control"),
        SystemShortcut(key: "ctrl+shift+up", hotKeyID: 34, name: "Mission Control (slow)"),
        SystemShortcut(key: "ctrl+down", hotKeyID: 33, name: "Application windows"),
        SystemShortcut(key: "ctrl+shift+down", hotKeyID: 35, name: "Application windows (slow)"),
        SystemShortcut(key: "ctrl+left", hotKeyID: 79, name: "Move left a space"),
        SystemShortcut(key: "ctrl+shift+left", hotKeyID: 80, name: "Move left a space (slow)"),
        SystemShortcut(key: "ctrl+right", hotKeyID: 81, name: "Move right a space"),
        SystemShortcut(key: "ctrl+shift+right", hotKeyID: 82, name: "Move right a space (slow)"),
        SystemShortcut(key: "ctrl+return", hotKeyID: 159, name: "Show contextual menu"),
        SystemShortcut(key: "shift+cmd+3", hotKeyID: 28, name: "Save picture of screen as a file"),
        SystemShortcut(key: "ctrl+shift+cmd+3", hotKeyID: 29, name: "Copy picture of screen to the clipboard"),
        SystemShortcut(key: "shift+cmd+4", hotKeyID: 30, name: "Save picture of selected area as a file"),
        SystemShortcut(key: "ctrl+shift+cmd+4", hotKeyID: 31, name: "Copy picture of selected area to the clipboard"),
        SystemShortcut(key: "shift+cmd+5", hotKeyID: 184, name: "Screenshot and recording options"),
        // macOS 26: Touch Bar picture (181, 182); macOS 27: Ask Siri about selected area (261).
        SystemShortcut(key: "shift+cmd+6", hotKeyID: 261, name: "Ask Siri about selected area / Touch Bar picture"),
        SystemShortcut(key: "ctrl+shift+cmd+6", hotKeyID: 182, name: "Copy picture of the Touch Bar (macOS 26)"),
        SystemShortcut(key: "shift+cmd+7", hotKeyID: 181, name: "Save picture of the Touch Bar (macOS 27)"),
        SystemShortcut(key: "ctrl+shift+cmd+7", hotKeyID: 182, name: "Copy picture of the Touch Bar (macOS 27)"),
        SystemShortcut(key: "shift+cmd+space", hotKeyID: 263, name: "Ask Siri about active window (macOS 27)"),
        SystemShortcut(key: "shift+cmd+/", hotKeyID: 98, name: "Show Help menu"),
        SystemShortcut(key: "ctrl+cmd+q", hotKeyID: nil, name: "Lock Screen"),
        SystemShortcut(key: "shift+cmd+q", hotKeyID: nil, name: "Log Out"),
        SystemShortcut(key: "opt+shift+cmd+q", hotKeyID: nil, name: "Log Out without asking"),
    ]

    /// Default keys that still take a macOS shortcut, each waiting for its new key. Keep this
    /// list short: ``everyWaitingKeyStillConflicts`` fails as soon as one is fixed, so its row goes.
    nonisolated static let awaitingNewKey: [String: String] = [
        "splitBrowserRight": "Opt-Cmd-D is macOS's Dock hiding (hot key 52, on by default); the new key is Lawrence's call",
    ]

    /// A keybindings.json stroke (`ctrl+cmd+d`) as a ``Shortcut``.
    static func shortcut(_ text: String) throws -> Shortcut {
        var modifiers: NSEvent.ModifierFlags = []
        var key: String?
        for token in text.lowercased().split(separator: "+").map(String.init) {
            switch token {
            case "cmd": modifiers.insert(.command)
            case "opt": modifiers.insert(.option)
            case "ctrl": modifiers.insert(.control)
            case "shift": modifiers.insert(.shift)
            case "left": key = Shortcut.leftArrowKey
            case "right": key = Shortcut.rightArrowKey
            case "up": key = Shortcut.upArrowKey
            case "down": key = Shortcut.downArrowKey
            case "return": key = Shortcut.returnKey
            case "tab": key = Shortcut.tabKey
            case "escape": key = Shortcut.escapeKey
            case "space": key = Shortcut.spaceKey
            default: key = token
            }
        }
        return Shortcut(try #require(key, "no key in \(text)"), modifiers: modifiers)
    }

    static func taken() throws -> [Shortcut: SystemShortcut] {
        var taken: [Shortcut: SystemShortcut] = [:]
        for system in onByDefault { taken[try shortcut(system.key)] = system }
        return taken
    }

    /// Each default stroke (single keys, aliases and every stroke of a chord) of the shipped binding
    /// table (no user files) whose key macOS keeps for itself.
    static func conflicts() throws -> [(action: String, stroke: Shortcut, system: SystemShortcut)] {
        let taken = try taken()
        let table = RegistryKeyBindings(ActionRegistry.standard()).table
        var found: [(action: String, stroke: Shortcut, system: SystemShortcut)] = []
        for entry in table.entries {
            for stroke in entry.keys {
                if let system = taken[stroke] { found.append((entry.command.rawValue, stroke, system)) }
            }
        }
        return found
    }

    @Test func theTableParses() throws {
        #expect(try Self.taken().count == Self.onByDefault.count, "a combo is listed twice")
        #expect(try Self.taken()[Shortcut("d", modifiers: [.control, .command])]?.hotKeyID == 70)
    }

    /// The regression: Ctrl-Cmd-D (Look Up) was New Column's default and never reached cmux.
    @Test func noDefaultKeyIsAMacOSShortcutThatIsOnByDefault() throws {
        let found = try Self.conflicts().filter { Self.awaitingNewKey[$0.action] == nil }
        #expect(found.isEmpty, """
        Default keys macOS takes first (the action never runs on a Mac with default settings): \
        \(found.map { "\($0.action) = \($0.stroke.displayString) is macOS's \($0.system.testDescription)" })
        """)
    }

    /// The shortcut recorder (Settings > Keyboard, the palette) refuses Look Up's key, so a person
    /// cannot record New Column back onto a key that never reaches cmux.
    @Test func theRecorderRefusesLookUp() {
        #expect(SystemReservedShortcuts.shared.table[Shortcut("d", modifiers: [.control, .command])] == "Look Up")
    }

    @Test func everyWaitingKeyStillConflicts() throws {
        let actions = Set(try Self.conflicts().map(\.action))
        for (action, why) in Self.awaitingNewKey {
            #expect(actions.contains(action), "\(action) no longer takes a macOS shortcut: remove its awaitingNewKey row (\(why))")
        }
    }

    /// New Column's key runs New Column in every pane focus the Ghostty-reserved list checks.
    @Test func newColumnsKeyRunsNewColumnInEveryPane() throws {
        let registry = ActionRegistry.standard()
        let key = Shortcut("x", modifiers: [.control, .command])
        #expect(registry.descriptor(for: "newColumn")?.defaultShortcut == key)
        let table = RegistryKeyBindings(registry).table
        for context in GhosttyReservedKeysTests.contexts {
            let winner = table.resolve([key], in: KeyContext(context.values), isRunnable: { _ in true }).winner
            #expect(winner?.command.rawValue == "newColumn", "\(key.displayString) in \(context.name) runs \(winner?.command.rawValue ?? "nothing")")
        }
    }
}
