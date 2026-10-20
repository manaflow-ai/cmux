public import AppKit

/// Default entries that are not an action's own catalog key (plans/cmux-next/keybindings.md
/// section 5).
///
/// Every entry here is a cmux default: cmux.json and the user's own Ghostty keybinds win over
/// it, Ghostty's defaults lose to it (cmux.json > the user's Ghostty config > cmux defaults >
/// Ghostty defaults, with no forced tier; Lawrence 2026-10-20).
///
/// - Cmd-Shift-] / [ are aliases for Next / Previous Tab in Pane (`nextSurface` /
///   `prevSurface`, catalog keys Ctrl-Tab / Ctrl-Shift-Tab), as Ghostty's `next_tab` /
///   `previous_tab` defaults and the shipping cmux.
/// - Ctrl-Cmd arrows are aliases for the pane-resize actions (Ghostty's
///   `resize_split` defaults); their catalog keys are Ctrl-Shift H/J/K/L.
/// - Ctrl-Cmd H/J/K/L are aliases for the pane-focus actions, whose catalog
///   keys are Cmd-Opt arrows, Ghostty's `goto_split` defaults
///   (PANE-FOCUS-RESIZE-KEYS-AND-GHOSTTY-KEYBINDS).
public nonisolated struct KeyBindingDefaults {
    public nonisolated init() {}
    static let right = String(Character(UnicodeScalar(UInt32(NSRightArrowFunctionKey)) ?? UnicodeScalar(0)))
    static let left = String(Character(UnicodeScalar(UInt32(NSLeftArrowFunctionKey)) ?? UnicodeScalar(0)))
    static let up = String(Character(UnicodeScalar(UInt32(NSUpArrowFunctionKey)) ?? UnicodeScalar(0)))
    static let down = String(Character(UnicodeScalar(UInt32(NSDownArrowFunctionKey)) ?? UnicodeScalar(0)))
    public static let pageUp = String(Character(UnicodeScalar(UInt32(NSPageUpFunctionKey)) ?? UnicodeScalar(0)))
    public static let pageDown = String(Character(UnicodeScalar(UInt32(NSPageDownFunctionKey)) ?? UnicodeScalar(0)))
    public static let home = String(Character(UnicodeScalar(UInt32(NSHomeFunctionKey)) ?? UnicodeScalar(0)))
    public static let end = String(Character(UnicodeScalar(UInt32(NSEndFunctionKey)) ?? UnicodeScalar(0)))

    public static let notTerminal = WhenClause.notEquals(KeyContext.surfaceKind, .string("terminal"))

    /// Cmd-Shift-] / [ step the focused pane's tabs (Lawrence 2026-10-15: switching
    /// workspaces on them is "extremely bad"); Ctrl-Tab / Ctrl-Shift-Tab are the catalog keys.
    public static let tabCycleAliases: [KeyBinding] = [
        KeyBinding(keys: [Shortcut("]", modifiers: [.command, .shift])], command: "nextSurface"),
        KeyBinding(keys: [Shortcut("[", modifiers: [.command, .shift])], command: "prevSurface"),
    ]

    /// Scoped defaults that replace a global default key in their context:
    /// placed after the catalog's defaults, so in their context they win and
    /// elsewhere the global key runs. Any page adds its own keys here with a
    /// `when` that names it.
    ///
    /// Cmd-N is New Workspace everywhere, Home too (Lawrence 2026-10-20: "Command + N needs to
    /// always make a new workspace"); New Message keeps its compose button, palette and menu.
    ///
    /// Cmd-K searches the agent chats everywhere but a terminal, as in ChatGPT and Claude
    /// desktop (Leo 2026-10-12, keyboard parity); a focused terminal keeps Clear (decision K1)
    /// and the code editor keeps its Cmd-K key sequences.
    @MainActor static func scopedEntries(registry: ActionRegistry) -> [KeyBinding] {
        scopedDefaults.filter { binding in
            registry.disabledFeature(for: binding.command) == nil && registry.shortcutOverrides[binding.command] == nil
                && registry.chordOverrides[binding.command] == nil
        }
    }

    /// The scoped defaults without the registry's unbinding applied.
    public static let scopedDefaults: [KeyBinding] = [
        KeyBinding(keys: [Shortcut("k", modifiers: [.command])], command: "agentPane.searchChats",
                   when: .and([notTerminal, .not(.has(KeyContext.codeEditorFocusedKey))])),
    ]

    /// Home has the keyboard: its top page, its conversation view, or the docked Home's page.
    public static let onHome = WhenClause.or([
        .equals(KeyContext.topPage, .string("home")),
        .equals(KeyContext.surfaceKind, .string("home")),
        .equals(KeyContext.surfaceKind, .string("home-dock")),
    ])

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

    /// Cmd-[ / Cmd-] are focus history Back / Forward everywhere but a web
    /// page, as in the shipping cmux (chief decision, cx-442;
    /// plans/cmux-next/terminal-shortcuts.md). In a terminal they win over
    /// Ghostty's default `goto_split:previous/next`; a `super+[` keybind in the
    /// user's Ghostty config still wins over them. In a web page, the Markdown
    /// viewer and other surfaces with their own Back / Forward, the more
    /// specific catalog entry on the same key comes later and wins.
    public static let focusHistoryAliases: [KeyBinding] = [
        KeyBinding(keys: [Shortcut("[", modifiers: [.command])], command: "focusHistoryBack", when: notWebPage),
        KeyBinding(keys: [Shortcut("]", modifiers: [.command])], command: "focusHistoryForward", when: notWebPage),
    ]
    /// Cmd-Shift-= (Cmd-+ on a US layout) is the markdown viewer's Zoom In too, as Cmd-= is: the
    /// key a person reads as "Command plus". The action needs `markdownFocused`, so a terminal or a
    /// browser page never loses the key to it.
    public static let zoomAliases: [KeyBinding] = [
        KeyBinding(keys: [Shortcut("=", modifiers: [.command, .shift])], command: "markdownZoomIn"),
    ]

    /// Not in a web page, and not in the code editor, whose Cmd-[ / Cmd-] are outdent / indent.
    static let notWebPage = WhenClause.and([
        .notEquals(KeyContext.surfaceKind, .string("page")), .not(.has(KeyContext.codeEditorFocusedKey)),
    ])

    /// Aliases that follow their action's catalog key: present only while
    /// the action has its default key (no cmux.json override or chord).
    public static var actionAliases: [KeyBinding] { tabCycleAliases + paneResizeAliases + paneFocusAliases + focusHistoryAliases + zoomAliases }

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
        // VS Code's Insert Line Below / Above (Cmd-Return, Shift-Cmd-Return; Lawrence 2026-10-19:
        // "all common vscode shortcuts").
        "toggleChecklistItemComplete", "toggleSplitZoom",
    ]

    /// Actions whose default key a terminal program also uses (Ctrl-_ is
    /// readline/emacs undo): their default binding applies everywhere but a
    /// focused terminal (`notTerminal`, like Ctrl-Tab under K-T1;
    /// PANE-FOCUS-RESIZE-KEYS-AND-GHOSTTY-KEYBINDS amendment 3). A user
    /// binding keeps its own `when`.
    /// Cmd-=/-/0 and Cmd-Shift-G are Ghostty's per-terminal font size and previous match in a
    /// focused terminal, as in Ghostty and the shipping cmux (decision K1 follow-up, 2026-10-06).
    /// Cmd-Return (checklist item) reaches the terminal program, as in the shipping cmux
    /// (plans/cmux-next/terminal-shortcuts.md).
    public static let yieldsToTerminal: Set<ActionID> = [
        "focusHistoryBack", "focusHistoryForward",
        "increaseWorkspaceTerminalFontSize", "decreaseWorkspaceTerminalFontSize", "resetWorkspaceTerminalFontSize",
        "groupSelectedWorkspaces", "toggleChecklistItemComplete",
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
            // Tab opens the Actions menu; Cmd-K shows or hides it too (Copy Session ID on a
            // Go to Workspace row), and on an action row edits its shortcut.
            bind("k", [.command], "paletteKey.toggleActions", open),
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

    /// The aliases whose action still has its default key, then list
    /// navigation (removed one by one with `-list.next` entries in
    /// keybindings.json).
    @MainActor static func entries(registry: ActionRegistry) -> [KeyBinding] {
        var entries = actionAliases.filter { binding in
            registry.effectiveShortcut(for: binding.command) != nil
                && !registry.shortcutOverrides.keys.contains(binding.command)
                && registry.chordOverrides[binding.command] == nil
        }
        entries += listNavigation.filter { registry.disabledFeature(for: $0.command) == nil }
        entries += paletteKeys
        return entries
    }
}
