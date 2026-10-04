public import AppKit

/// Default entries that are not an action's own catalog key: the tab-switch
/// keys every browser and terminal knows (plans/cmux-next/keybindings.md
/// section 5). They sit first in the table, so any catalog or user binding
/// of the same key wins over them.
///
/// - Ctrl-Tab, Ctrl-Shift-Tab, Ctrl-PageDown, Ctrl-PageUp change tabs in
///   every surface but a terminal, whose Ghostty keybind
///   (`ctrl+tab=next_tab`, the same action) keeps them, so the user's
///   Ghostty config decides there (K-T1);
/// - in terminal copy mode, which takes every key before Ghostty, Ctrl-Tab
///   and Ctrl-Shift-Tab change tabs too;
/// - Cmd-Opt-Right/Left and Cmd-Shift-]/[ are a browser's next/previous tab
///   in a web page, when no cmux binding claims them.
///
/// Unbinding `nextSurface` or `prevSurface` in cmux.json removes its entries.
public nonisolated struct KeyBindingDefaults {
    public nonisolated init() {}
    static let right = String(Character(UnicodeScalar(UInt32(NSRightArrowFunctionKey))!))
    static let left = String(Character(UnicodeScalar(UInt32(NSLeftArrowFunctionKey))!))
    public static let pageUp = String(Character(UnicodeScalar(UInt32(NSPageUpFunctionKey))!))
    public static let pageDown = String(Character(UnicodeScalar(UInt32(NSPageDownFunctionKey))!))

    public static let notTerminal = WhenClause.notEquals(KeyContext.surfaceKind, .string("terminal"))
    static let terminalCopyMode = WhenClause.and([
        .equals(KeyContext.surfaceKind, .string("terminal")), .has(KeyContext.terminalCopyMode),
    ])
    static let webPage = WhenClause.equals(KeyContext.surfaceKind, .string("page"))

    /// The entries, without the registry's unbinding applied.
    public static let tabSwitching: [KeyBinding] = [
        KeyBinding(keys: [Shortcut("\t", modifiers: [.control])], command: "nextSurface", when: notTerminal),
        KeyBinding(keys: [Shortcut("\t", modifiers: [.control, .shift])], command: "prevSurface", when: notTerminal),
        KeyBinding(keys: [Shortcut(pageDown, modifiers: [.control])], command: "nextSurface", when: notTerminal),
        KeyBinding(keys: [Shortcut(pageUp, modifiers: [.control])], command: "prevSurface", when: notTerminal),
        KeyBinding(keys: [Shortcut("\t", modifiers: [.control])], command: "nextSurface", when: terminalCopyMode),
        KeyBinding(keys: [Shortcut("\t", modifiers: [.control, .shift])], command: "prevSurface", when: terminalCopyMode),
        KeyBinding(keys: [Shortcut(right, modifiers: [.command, .option])], command: "nextSurface", when: webPage),
        KeyBinding(keys: [Shortcut(left, modifiers: [.command, .option])], command: "prevSurface", when: webPage),
        KeyBinding(keys: [Shortcut("]", modifiers: [.command, .shift])], command: "nextSurface", when: webPage),
        KeyBinding(keys: [Shortcut("[", modifiers: [.command, .shift])], command: "prevSurface", when: webPage),
    ]

    /// The entries whose action still has a key in `registry`.
    @MainActor static func entries(registry: ActionRegistry) -> [KeyBinding] {
        tabSwitching.filter { registry.effectiveShortcut(for: $0.command) != nil }
    }
}
