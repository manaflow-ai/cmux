import AppKit
import Carbon.HIToolbox
import CmuxNextActions
import Testing

/// Ctrl-Cmd-= equalizes the splits (Ghostty's `equalize_splits` key), and Ctrl-Shift-Cmd-= / - / 0
/// step the interface scale, the size of all app text (Lawrence 2026-10-19: "Command+Control+=
/// should equalize and for changing font size we should do Command+Shift+Control++ and -").
/// A key press resolves to the action the key router runs, in every focus.
@MainActor @Suite struct EqualizeAndInterfaceScaleKeysTests {
    nonisolated static let contexts: [ActionContext] = [[], .terminalFocused, .browserFocused, .markdownFocused, .agentPaneFocused]

    nonisolated static let keys: [(String, Int, NSEvent.ModifierFlags, String)] = [
        ("=", kVK_ANSI_Equal, [.control, .command], "equalizeSplits"),
        ("=", kVK_ANSI_Equal, [.control, .shift, .command], "appearance.uiScale.increase"),
        ("-", kVK_ANSI_Minus, [.control, .shift, .command], "appearance.uiScale.decrease"),
        ("0", kVK_ANSI_0, [.control, .shift, .command], "appearance.uiScale.reset"),
    ]

    @Test(arguments: keys, contexts)
    func keyRunsItsAction(key: (String, Int, NSEvent.ModifierFlags, String), context: ActionContext) throws {
        let (character, keyCode, modifiers, action) = key
        // The app binds a handler to every catalog action; a key runs only a bound one.
        let registry = ActionRegistry.standard()
        for descriptor in ActionCatalog.all { registry.bind(descriptor.id) {} }
        registry.context = context
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
            characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: UInt16(keyCode)
        ))
        #expect(registry.resolveShortcut(for: event)?.id.rawValue == action)
    }

    /// The keys the menus, Settings and Cmd-Shift-P show are the same defaults.
    @Test func defaultShortcutsAreTheNewKeys() {
        let registry = ActionRegistry.standard()
        #expect(registry.effectiveShortcut(for: "equalizeSplits") == Shortcut("=", modifiers: [.control, .command]))
        #expect(registry.effectiveShortcut(for: "appearance.uiScale.increase") == Shortcut("=", modifiers: [.control, .shift, .command]))
        #expect(registry.effectiveShortcut(for: "appearance.uiScale.decrease") == Shortcut("-", modifiers: [.control, .shift, .command]))
        #expect(registry.effectiveShortcut(for: "appearance.uiScale.reset") == Shortcut("0", modifiers: [.control, .shift, .command]))
    }

    /// No other catalog action has one of these four keys as its default.
    @Test func noOtherActionDefaultsToTheseKeys() {
        let owned: [Shortcut: String] = [
            Shortcut("=", modifiers: [.control, .command]): "equalizeSplits",
            Shortcut("=", modifiers: [.control, .shift, .command]): "appearance.uiScale.increase",
            Shortcut("-", modifiers: [.control, .shift, .command]): "appearance.uiScale.decrease",
            Shortcut("0", modifiers: [.control, .shift, .command]): "appearance.uiScale.reset",
        ]
        for descriptor in ActionCatalog.all {
            guard let shortcut = descriptor.defaultShortcut, let owner = owned[shortcut] else { continue }
            #expect(descriptor.id.rawValue == owner, "\(descriptor.id.rawValue) also defaults to \(owner)'s key")
        }
    }
}
