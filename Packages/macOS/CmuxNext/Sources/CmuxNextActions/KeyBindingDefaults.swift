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
/// - Ctrl-Cmd arrows are aliases for the pane-resize actions (Ghostty's
///   `resize_split` defaults); their catalog keys are Ctrl-Shift H/J/K/L.
/// - Ctrl-Cmd H/J/K/L are aliases for the pane-focus actions, whose catalog
///   keys are Cmd-Opt arrows (PANE-FOCUS-RESIZE-KEYS-AND-GHOSTTY-KEYBINDS).
///
/// Unbinding `nextSurface` or `prevSurface` in cmux.json removes its entries.
public nonisolated struct KeyBindingDefaults {
    public nonisolated init() {}
    static let right = String(Character(UnicodeScalar(UInt32(NSRightArrowFunctionKey))!))
    static let left = String(Character(UnicodeScalar(UInt32(NSLeftArrowFunctionKey))!))
    static let up = String(Character(UnicodeScalar(UInt32(NSUpArrowFunctionKey)) ?? UnicodeScalar(0)))
    static let down = String(Character(UnicodeScalar(UInt32(NSDownArrowFunctionKey)) ?? UnicodeScalar(0)))
    public static let pageUp = String(Character(UnicodeScalar(UInt32(NSPageUpFunctionKey))!))
    public static let pageDown = String(Character(UnicodeScalar(UInt32(NSPageDownFunctionKey))!))
    public static let home = String(Character(UnicodeScalar(UInt32(NSHomeFunctionKey)) ?? UnicodeScalar(0)))
    public static let end = String(Character(UnicodeScalar(UInt32(NSEndFunctionKey)) ?? UnicodeScalar(0)))

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

    /// The Home top page (`topPage` home): Cmd-Shift-[ / ] move between
    /// conversations instead of tabs. A Home conversation tab inside a
    /// workspace (`surfaceKind` home there too) keeps tab switching.
    static let homeShown = WhenClause.equals(KeyContext.topPage, .string("home"))
    public static let homeNavigation: [KeyBinding] = [
        KeyBinding(keys: [Shortcut("[", modifiers: [.command, .shift])], command: "home.previousConversation", when: homeShown),
        KeyBinding(keys: [Shortcut("]", modifiers: [.command, .shift])], command: "home.nextConversation", when: homeShown),
    ]

    /// Scoped defaults that replace a global default key in their context
    /// (Home's Cmd-Shift-[ / ]): placed after the catalog's defaults, so in
    /// their context they win and elsewhere the global key runs. Any page
    /// adds its own keys here with a `when` that names it.
    @MainActor static func scopedEntries(registry: ActionRegistry) -> [KeyBinding] {
        homeNavigation.filter { registry.descriptor(for: $0.command) != nil && registry.disabledFeature(for: $0.command) == nil }
    }

    /// The arrow aliases for pane resize. These are defaults in addition to
    /// each action's catalog Ctrl-Shift H/J/K/L key, and disappear when a user
    /// overrides or unbinds that action.
    public static let paneResizeAliases: [KeyBinding] = [
        KeyBinding(keys: [Shortcut(left, modifiers: [.control, .command])], command: "resizePaneLeft"),
        KeyBinding(keys: [Shortcut(right, modifiers: [.control, .command])], command: "resizePaneRight"),
        KeyBinding(keys: [Shortcut(up, modifiers: [.control, .command])], command: "resizePaneUp"),
        KeyBinding(keys: [Shortcut(down, modifiers: [.control, .command])], command: "resizePaneDown"),
    ]

    /// The vim-letter aliases for pane focus, in addition to each action's
    /// catalog Cmd-Opt arrow; they disappear when a user overrides or
    /// unbinds that action.
    public static let paneFocusAliases: [KeyBinding] = [
        KeyBinding(keys: [Shortcut("h", modifiers: [.control, .command])], command: "focusLeft"),
        KeyBinding(keys: [Shortcut("j", modifiers: [.control, .command])], command: "focusDown"),
        KeyBinding(keys: [Shortcut("k", modifiers: [.control, .command])], command: "focusUp"),
        KeyBinding(keys: [Shortcut("l", modifiers: [.control, .command])], command: "focusRight"),
    ]

    /// Aliases that follow their action's catalog key: present only while
    /// the action has its default key (no cmux.json override or chord).
    public static var actionAliases: [KeyBinding] { paneResizeAliases + paneFocusAliases }

    /// Actions whose default key Monaco also uses for editing (R127,
    /// webviews/src/pages/editor/README.md): while the code editor has the
    /// keyboard (`codeEditorFocused`) their default binding steps aside and
    /// the key reaches the editor. A user binding keeps its own `when`.
    /// App-global chords (Cmd-T, Cmd-W, Cmd-N, Cmd-1…9, Ctrl-1…9,
    /// Shift-Cmd-P, Cmd-Q, Cmd-comma, Shift-Cmd-T) are not here.
    public static let yieldsToCodeEditor: Set<ActionID> = [
        "splitRight", "openBrowser", "focusUp", "focusDown",
        "moveSurfaceToPaneLeft", "moveSurfaceToPaneRight", "moveSurfaceToPaneUp", "moveSurfaceToPaneDown",
        "space.previous", "space.next", "globalSearch", "palette.newAgentChat", "focusLocation", "groupSelectedWorkspaces",
    ]

    /// Actions whose default key a terminal program also uses (Ctrl-_ is
    /// readline/emacs undo): their default binding applies everywhere but a
    /// focused terminal (`notTerminal`, like Ctrl-Tab under K-T1;
    /// PANE-FOCUS-RESIZE-KEYS-AND-GHOSTTY-KEYBINDS amendment 3). A user
    /// binding keeps its own `when`.
    /// Cmd-=/-/0 and Cmd-Shift-G are Ghostty's per-terminal font size and previous match in a
    /// focused terminal, as in Ghostty and the shipping cmux (decision K1 follow-up, 2026-10-06).
    public static let yieldsToTerminal: Set<ActionID> = [
        "focusHistoryBack", "focusHistoryForward",
        "increaseWorkspaceTerminalFontSize", "decreaseWorkspaceTerminalFontSize", "resetWorkspaceTerminalFontSize",
        "groupSelectedWorkspaces",
    ]

    /// The command palette's keys (R59 fold, `PaletteKeyActionCatalog`), in
    /// table order: a later applicable entry wins, so a more specific
    /// `when` follows a general one for the same key.
    public static let paletteKeys: [KeyBinding] = {
        typealias K = KeyContext
        let open = WhenClause.has("paletteOpen")
        func when(_ clauses: WhenClause...) -> WhenClause { .and([open] + clauses) }
        let tree = WhenClause.has(K.paletteHierarchical), menu = WhenClause.has(K.paletteActionsMenuOpen)
        let empty = WhenClause.has(K.paletteQueryEmpty)
        func bind(_ key: String, _ modifiers: NSEvent.ModifierFlags, _ id: ActionID, _ clause: WhenClause) -> KeyBinding {
            KeyBinding(keys: [Shortcut(key, modifiers: modifiers)], command: id, when: clause)
        }
        return [
            bind(Shortcut.upArrowKey, [], "commandPalettePrevious", open),
            bind(Shortcut.downArrowKey, [], "commandPaletteNext", open),
            bind(Shortcut.upArrowKey, [.command], "paletteKey.firstItem", open),
            bind(Shortcut.upArrowKey, [.command], "paletteKey.leaveLevel", when(tree, .not(menu))),
            bind(Shortcut.downArrowKey, [.command], "paletteKey.lastItem", open),
            bind(pageUp, [], "paletteKey.pageUp", open),
            bind(pageDown, [], "paletteKey.pageDown", open),
            bind(home, [], "paletteKey.firstItem", when(.or([menu, .and([tree, empty])]))),
            bind(end, [], "paletteKey.lastItem", when(.or([menu, .and([tree, empty])]))),
            bind(Shortcut.returnKey, [], "paletteKey.submit", open),
            bind(Shortcut.returnKey, [.shift], "paletteKey.submit", open),
            bind(Shortcut.returnKey, [.option], "paletteKey.submit", open),
            bind(Shortcut.returnKey, [.command], "paletteKey.submitAlternate", open),
            bind(Shortcut.returnKey, [.command, .shift], "paletteKey.submitAlternate", open),
            bind(Shortcut.spaceKey, [], "paletteKey.submit", when(empty, .has(K.paletteTogglesInPlace), .not(menu))),
            bind(Shortcut.tabKey, [], "paletteKey.openActions", open),
            bind(Shortcut.tabKey, [.shift], "paletteKey.closeActions", open),
            // Decision K1: no Cmd-K in the palette; Tab opens the Actions menu.
            bind(Shortcut.escapeKey, [], "paletteKey.escape", open),
            bind(Shortcut.rightArrowKey, [], "paletteKey.enterRow", when(tree, .not(menu), .has(K.paletteCaretAtEnd))),
            bind(Shortcut.leftArrowKey, [], "paletteKey.leaveLevel", when(tree, .not(menu), .has(K.paletteCaretAtStart))),
            bind(Shortcut.deleteKey, [], "paletteKey.back", when(empty, .not(menu))),
            bind(Shortcut.deleteKey, [], "paletteKey.filterDeleteBackward", when(menu)),
            bind("w", [.command], "paletteKey.closeItem", open),
        ]
    }()

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
        entries += actionAliases.filter { binding in
            registry.effectiveShortcut(for: binding.command) != nil
                && !registry.shortcutOverrides.keys.contains(binding.command)
                && registry.chordOverrides[binding.command] == nil
        }
        entries += listNavigation.filter { registry.disabledFeature(for: $0.command) == nil }
        entries += paletteKeys
        return entries
    }
}
