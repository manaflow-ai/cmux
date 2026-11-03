import AppKit
import CmuxNextActions
import Foundation
import Testing

/// Split Browser Right's default key reaches cmux on a Mac with default settings. It was Opt-Cmd-D,
/// macOS's "Turn Dock hiding on/off" (system hot key 52, on by default on macOS 14, 15, 26 and 27:
/// Apple, "Mac keyboard shortcuts", https://support.apple.com/en-us/102650, "Option-Command-D: Show
/// or hide the Dock"; System Settings' KeyboardSettings.appex DefaultShortcutsTable.xml of each
/// version; the window server's live table on fleet Macs). The window server takes it before cmux
/// sees it, so Split Browser Right never ran from its key (the same fault as New Column's Ctrl-Cmd-D
/// and macOS's Look Up). The new key, Opt-Cmd-L, has no row (on or off) in those tables.
@MainActor @Suite struct SplitBrowserRightKeyTests {
    static let dockHiding = Shortcut("d", modifiers: [.option, .command])
    static let key = Shortcut("l", modifiers: [.option, .command])

    @Test func noDefaultBindingOfSplitBrowserRightIsMacOSsDockHidingKey() {
        let registry = ActionRegistry.standard()
        #expect(registry.descriptor(for: "splitBrowserRight")?.defaultShortcut != Self.dockHiding)
        let entries = RegistryKeyBindings(registry).table.entries.filter { $0.command.rawValue == "splitBrowserRight" }
        #expect(!entries.contains { $0.keys.contains(Self.dockHiding) }, "Opt-Cmd-D is macOS's Dock hiding (hot key 52)")
    }

    /// The new key runs Split Browser Right in every pane focus the Ghostty-reserved list checks.
    @Test func theNewKeyRunsSplitBrowserRightInEveryPane() {
        let registry = ActionRegistry.standard()
        #expect(registry.descriptor(for: "splitBrowserRight")?.defaultShortcut == Self.key)
        let table = RegistryKeyBindings(registry).table
        for context in GhosttyReservedKeysTests.contexts {
            let winner = table.resolve([Self.key], in: KeyContext(context.values), isRunnable: { _ in true }).winner
            #expect(winner?.command.rawValue == "splitBrowserRight",
                    "\(Self.key.displayString) in \(context.name) runs \(winner?.command.rawValue ?? "nothing")")
        }
    }
}
