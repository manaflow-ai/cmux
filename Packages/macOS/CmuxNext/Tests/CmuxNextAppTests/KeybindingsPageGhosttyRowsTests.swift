import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextSettings
import Testing

/// The Keyboard Shortcuts page lists the Ghostty config's keybinds
/// (GHOSTTY-CONFIG): the user's as source `ghostty`, Ghostty's defaults as
/// `ghostty-fallback` ("Ghostty default"), and a user keybind once (its
/// app-wide fallback entry is not a second row).
@MainActor
struct KeybindingsPageGhosttyRowsTests {
    static let commandD = Shortcut("d", modifiers: [.command])
    static let nextTab = Shortcut("]", modifiers: [.command, .shift])

    static func registry() -> ActionRegistry {
        let registry = KeybindingReportTests.registry()
        KeyBindingLoader(registry).loadGhostty([
            // The user's `super+d=new_split:down`.
            KeyBinding(keys: [commandD], command: "splitDown", source: .ghosttyFallback),
            KeyBinding(keys: [commandD], command: "splitDown", when: GhosttyKeyBindingLayer.terminalFocused, source: .ghostty),
            // Ghostty's default `super+shift+]=next_tab`.
            KeyBinding(keys: [nextTab], command: "nextSurface", source: .ghosttyFallback),
        ])
        return registry
    }

    @Test func thePageListsTheUsersGhosttyKeybindOnceAndGhosttyDefaults() {
        let rows = KeybindingReportTests.bindings(KeybindingReports.pageList([:], registry: Self.registry()))
        let splitDown = rows.filter { $0["command"] == "splitDown" && $0["source"]?.stringValue?.hasPrefix("ghostty") == true }
        #expect(splitDown.map { $0["source"] } == ["ghostty"])
        let nextSurface = rows.filter { $0["command"] == "nextSurface" && $0["source"]?.stringValue?.hasPrefix("ghostty") == true }
        #expect(nextSurface.map { $0["source"] } == ["ghostty-fallback"])
    }

    /// The socket's `keybinding.list` keeps every table entry.
    @Test func theSocketListKeepsEveryGhosttyEntry() {
        let rows = KeybindingReportTests.bindings(KeybindingReports.list([:], registry: Self.registry()))
        #expect(rows.filter { $0["command"] == "splitDown" && $0["source"]?.stringValue?.hasPrefix("ghostty") == true }.count == 2)
    }
}
