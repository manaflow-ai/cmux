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
/// - Ctrl-Cmd arrows are aliases for the pane-resize actions. Their catalog
///   defaults are also available as Ctrl-Cmd H/J/K/L, so both familiar
///   layouts work without a user override.
///
/// Unbinding `nextSurface` or `prevSurface` in cmux.json removes its entries.
public nonisolated struct KeyBindingDefaults {
    public nonisolated init() {}
    static let right = String(Character(UnicodeScalar(UInt32(NSRightArrowFunctionKey))!))
    static let left = String(Character(UnicodeScalar(UInt32(NSLeftArrowFunctionKey))!))
    static let up = String(Character(UnicodeScalar(UInt32(NSUpArrowFunctionKey))!))
    static let down = String(Character(UnicodeScalar(UInt32(NSDownArrowFunctionKey))!))
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

    /// The arrow aliases for pane resize. These are defaults in addition to
    /// each action's catalog Ctrl-Cmd H/J/K/L key, and disappear when a user
    /// overrides or unbinds that action.
    public static let paneResizeAliases: [KeyBinding] = [
        KeyBinding(keys: [Shortcut(left, modifiers: [.control, .command])], command: "resizePaneLeft"),
        KeyBinding(keys: [Shortcut(right, modifiers: [.control, .command])], command: "resizePaneRight"),
        KeyBinding(keys: [Shortcut(up, modifiers: [.control, .command])], command: "resizePaneUp"),
        KeyBinding(keys: [Shortcut(down, modifiers: [.control, .command])], command: "resizePaneDown"),
    ]

    /// List navigation (R85): Ctrl-N / Ctrl-J move down and Ctrl-P /
    /// Ctrl-K move up wherever a list-like control has the keyboard
    /// (`listFocus`: comboboxes, menus, pickers, the sidebar list). Never in
    /// a terminal or a plain text field, where `listFocus` is unset.
    public static let listFocus = WhenClause.has(KeyContext.listFocus)

    public static let listNavigation: [KeyBinding] = [
        KeyBinding(keys: [Shortcut("n", modifiers: [.control])], command: "list.next", when: listFocus),
        KeyBinding(keys: [Shortcut("j", modifiers: [.control])], command: "list.next", when: listFocus),
        KeyBinding(keys: [Shortcut("p", modifiers: [.control])], command: "list.previous", when: listFocus),
        KeyBinding(keys: [Shortcut("k", modifiers: [.control])], command: "list.previous", when: listFocus),
    ]

    /// The entries whose action still has a key in `registry` (tab
    /// switching follows its actions' keys), then list navigation (removed
    /// one by one with `-list.next` entries in keybindings.json).
    @MainActor static func entries(registry: ActionRegistry) -> [KeyBinding] {
        var entries = tabSwitching.filter { registry.effectiveShortcut(for: $0.command) != nil }
        entries += paneResizeAliases.filter { binding in
            registry.effectiveShortcut(for: binding.command) != nil
                && !registry.shortcutOverrides.keys.contains(binding.command)
                && registry.chordOverrides[binding.command] == nil
        }
        entries += listNavigation.filter { registry.disabledFeature(for: $0.command) == nil }
        return entries
    }
}
