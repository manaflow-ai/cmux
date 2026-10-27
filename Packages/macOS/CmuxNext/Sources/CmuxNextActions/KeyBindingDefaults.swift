public import AppKit

/// Default entries that are not an action's own catalog key (plans/cmux-next/keybindings.md
/// section 5).
///
/// The Chrome tab keys (`tabSwitching`, Leo 2026-10-12: "chrome/chatgpt/claude has them all
/// the same") select sidebar items, what Chrome calls tabs, from any focus:
/// - Ctrl-PageDown, Ctrl-Cmd-]: the next item;
/// - Ctrl-PageUp, Ctrl-Cmd-[: the previous item;
/// - Cmd-1 to Cmd-8 the nth item, Cmd-9 the last (`sidebar.cmd9`).
/// Ctrl-Tab / Ctrl-Shift-Tab and Cmd-Shift-] / [ cycle the focused pane's tabs instead
/// (`nextSurface` / `prevSurface`; Leo 2026-10-12: as a workspace switch they got
/// inconsistent once more was open; Lawrence 2026-10-15: Cmd-Shift-] / [ switching
/// workspaces is "extremely bad"). They are here too, so a terminal's Ghostty keybind
/// does not take them either.
/// They go after the Ghostty config's keybinds and claims, so a terminal, its Ghostty
/// keybinds (`ctrl+tab=next_tab`, `super+[`), a web page and the agent composer never take
/// them; only cmux.json entries and `-<id>` removals change them.
///
/// - Ctrl-Cmd arrows are aliases for the pane-resize actions (Ghostty's
///   `resize_split` defaults); their catalog keys are Ctrl-Shift H/J/K/L.
/// - Ctrl-Cmd H/J/K/L are aliases for pane focus, whose catalog keys are
///   the Cmd-Opt arrows (Ghostty's `goto_split`). Cmd-Opt-Left / Right are not
///   Chrome tab keys here (Lawrence 2026-10-20: "Command+Option+Arrow key needs
///   to be the original shortcut, which is the ghostty one"; 2f3e1f95983 had
///   made them sidebar keys). Ghostty's default split keys are reserved
///   (schemas/keybindings/ghostty-reserved-keys.json, GhosttyReservedKeysTests):
///   change one only with the user's explicit OK.
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

    /// The Chrome tab keys, without the registry's unbinding applied. The
    /// catalog keys of `nextSidebarTab` / `prevSidebarTab` (Ctrl-Cmd-] / [)
    /// and `selectWorkspaceByNumber` (Cmd-1…9) are here too, so they also win
    /// over a Ghostty keybind.
    public static let tabSwitching: [KeyBinding] = {
        func bind(_ key: String, _ modifiers: NSEvent.ModifierFlags, _ id: ActionID, _ argument: String? = nil) -> KeyBinding {
            KeyBinding(keys: [Shortcut(key, modifiers: modifiers)], command: id, argument: argument)
        }
        return [
            bind("\t", [.control], "nextSurface"), bind("\t", [.control, .shift], "prevSurface"),
            bind("]", [.command, .shift], "nextSurface"), bind("[", [.command, .shift], "prevSurface"),
            bind(pageDown, [.control], "nextSidebarTab"), bind(pageUp, [.control], "prevSidebarTab"),
            bind("]", [.control, .command], "nextSidebarTab"), bind("[", [.control, .command], "prevSidebarTab"),
        ] + (1...9).map { bind(String($0), [.command], "selectWorkspaceByNumber", String($0)) }
    }()

    /// The Chrome tab keys whose action is on and not removed or rebound
    /// in cmux.json (a rebound action keeps only its cmux.json key).
    @MainActor static func tabSwitching(registry: ActionRegistry) -> [KeyBinding] {
        tabSwitching.filter { binding in
            registry.disabledFeature(for: binding.command) == nil && registry.effectiveShortcut(for: binding.command) != nil
                && !registry.shortcutOverrides.keys.contains(binding.command) && registry.chordOverrides[binding.command] == nil
        }
    }

    /// Workspaces as tabs (`sidebar.workspacesAsTabs`, a Debug tunable, off; Leo, relayed
    /// 2026-10-21): Cmd-Shift-] / [ step the sidebar's workspaces (`nextSidebarTab` with `scope`
    /// `workspaces`: sidebar order, across groups, a collapsed group one stop, wrapping, never Home
    /// or another top item). They go after the Chrome tab keys, so they win over `nextSurface`.
    /// The table holds them only while the tunable is on (`ActionRegistry.includesWorkspaceTabKeys`),
    /// so off, the keymap, the shortcut list and its conflicts are the shipped ones. Home keeps its own keys.
    public static let workspacesAsTabs: [KeyBinding] = {
        let when = WhenClause.and([.has(KeyContext.workspacesAsTabs), .not(onHome)])
        let scope: [String: ActionValue] = ["scope": .string("workspaces")]
        return [
            KeyBinding(keys: [Shortcut("]", modifiers: [.command, .shift])], command: "nextSidebarTab", arguments: scope, when: when),
            KeyBinding(keys: [Shortcut("[", modifiers: [.command, .shift])], command: "prevSidebarTab", arguments: scope, when: when),
        ]
    }()

    /// Home's chat list has the keyboard (Lawrence 2026-10-21: "ctrl 1-9 and cmd shift [] and ctrl
    /// tab ... need to work for cycling through chiefs (only for home chief, if user opens chief in
    /// tab, then the kb shortcuts should be for normal tab stuff"): the Home top page or the docked
    /// Home's tab. A conversation opened as a pane tab (`surfaceKind == home`, no `topPage`) is a
    /// normal tab, so the tab keys keep their meaning there.
    public static let onHomeChats = WhenClause.or([
        .equals(KeyContext.topPage, .string("home")),
        .equals(KeyContext.surfaceKind, .string("home-dock")),
    ])

    /// The actions that step or pick a Home conversation: every key of theirs (a default, a cmux.json
    /// or a Settings rebind) runs only where ``onHomeChats`` holds, so a rebind never takes the key
    /// from a terminal or a pane's tabs (`RegistryKeyBindings`).
    public static let homeChatScoped: Set<ActionID> = [
        "home.nextConversation", "home.previousConversation", "home.selectConversationByNumber",
    ]

    /// The Chief chat's zoom: every key of theirs (a default, a cmux.json or a Settings rebind) runs only
    /// where ``onHome`` holds, so a rebind never zooms the Chief chat from a terminal or a browser.
    public static let homeScoped: Set<ActionID> = ["home.zoomIn", "home.zoomOut", "home.zoomReset"]

    /// The tab keys on Home: the keys that cycle a pane's tabs move through Home's chat list in
    /// sidebar order, wrapping as tabs do. Ctrl-Tab / Ctrl-Shift-Tab and Ctrl-1…9 are also the
    /// actions' catalog keys; Cmd-Shift-] / [ are aliases. They go after the Chrome tab keys
    /// (``tabSwitching``), which they replace on Home only.
    public static let homeChatSwitching: [KeyBinding] = {
        func bind(_ key: String, _ modifiers: NSEvent.ModifierFlags, _ id: ActionID, _ argument: String? = nil) -> KeyBinding {
            KeyBinding(keys: [Shortcut(key, modifiers: modifiers)], command: id, argument: argument, when: onHomeChats)
        }
        return [
            bind("\t", [.control], "home.nextConversation"), bind("\t", [.control, .shift], "home.previousConversation"),
            bind("]", [.command, .shift], "home.nextConversation"), bind("[", [.command, .shift], "home.previousConversation"),
        ] + (1...9).map { bind(String($0), [.control], "home.selectConversationByNumber", String($0)) }
    }()

    /// The Home tab keys whose action is on and keeps its default key: a rebound action (cmux.json,
    /// Settings) keeps only its own key, still scoped to Home (``homeChatScoped``).
    @MainActor static func homeChatSwitching(registry: ActionRegistry) -> [KeyBinding] {
        homeChatSwitching.filter { binding in
            registry.disabledFeature(for: binding.command) == nil && registry.effectiveShortcut(for: binding.command) != nil
                && registry.shortcutOverrides[binding.command] == nil && registry.chordOverrides[binding.command] == nil
        }
    }

    /// The workspaces-as-tabs keys while the tunable is on, whose action is on and not removed or rebound in cmux.json.
    @MainActor static func workspacesAsTabs(registry: ActionRegistry) -> [KeyBinding] {
        guard registry.includesWorkspaceTabKeys() else { return [] }
        return workspacesAsTabs.filter { binding in
            registry.disabledFeature(for: binding.command) == nil && registry.effectiveShortcut(for: binding.command) != nil
                && !registry.shortcutOverrides.keys.contains(binding.command) && registry.chordOverrides[binding.command] == nil
        }
    }

    /// Scoped defaults that replace a global default key in their context:
    /// placed after the catalog's defaults, so in their context they win and
    /// elsewhere the global key runs. Any page adds its own keys here with a
    /// `when` that names it. (Home's Cmd-Shift-[ / ] went to the Chrome tab
    /// keys, Leo 2026-10-12: Home is a sidebar item too.)
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
        // Cmd-Shift-R on Home: Reply to Selection (free in the defaults; Cmd-R is Rename Tab and Reload).
        KeyBinding(keys: [Shortcut("r", modifiers: [.command, .shift])], command: "home.replyToSelection", when: onHome),
        // Cmd-= / Cmd-+ / Cmd-- / Cmd-0 on Home zoom the Chief chat, as they zoom an agent chat or a page.
        KeyBinding(keys: [Shortcut("=", modifiers: [.command])], command: "home.zoomIn", when: onHome),
        KeyBinding(keys: [Shortcut("=", modifiers: [.command, .shift])], command: "home.zoomIn", when: onHome),
        KeyBinding(keys: [Shortcut("-", modifiers: [.command])], command: "home.zoomOut", when: onHome),
        KeyBinding(keys: [Shortcut("0", modifiers: [.command])], command: "home.zoomReset", when: onHome),
        // Cmd-W in the sidebar with several rows selected closes them, as Chrome's Cmd-W closes its
        // selected tabs (Leo 2026-10-20); with one row selected it still closes the shown tab.
        KeyBinding(keys: [Shortcut("w", modifiers: [.command])], command: "closeWorkspace", when: sidebarMultiSelection),
    ]

    /// The sidebar list has the keyboard with two or more rows selected.
    public static let sidebarMultiSelection = WhenClause.has(KeyContext.sidebarMultiSelection)

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
        KeyBinding(keys: [Shortcut("l", modifiers: [.control, .command])], command: "focusRight"),
        KeyBinding(keys: [Shortcut("j", modifiers: [.control, .command])], command: "focusDown"),
        KeyBinding(keys: [Shortcut("k", modifiers: [.control, .command])], command: "focusUp"),
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
    public static var actionAliases: [KeyBinding] { paneResizeAliases + paneFocusAliases + focusHistoryAliases + zoomAliases }

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

    /// Actions whose default key an agent chat or a web page also uses: their default binding
    /// applies everywhere but there (`notWebContent`), so the page's own handler gets the key.
    /// Cmd-Return steers a running agent turn in the composer (Composer.tsx) and submits forms
    /// on many sites; the checklist toggle took it first and refused "no todo items".
    public static let yieldsToWebContent: Set<ActionID> = ["toggleChecklistItemComplete"]

    /// Not an agent chat (`agent`, the acpmux page) and not a web page (`page`).
    public static let notWebContent = WhenClause.and([
        .notEquals(KeyContext.surfaceKind, .string("agent")), .notEquals(KeyContext.surfaceKind, .string("page")),
    ])

    /// The keys a focused text field or composer uses itself (Leo, 2026-10-20): Return sends and
    /// its Command, Shift and Option forms steer, add a line or send another way; Esc cancels or
    /// stops a turn; ↑ recalls a prompt or a queued one. A default binding on one of them steps
    /// aside while text input has the keyboard (`notTextInput`), so the field gets the key, unless
    /// its action is scoped to a surface (`requires`: the omnibar's Cmd-Return, the file explorer's
    /// Return).
    /// The checklist toggle took Cmd-Return from the chat composer and refused "no todo items".
    public static let textInputKeys: Set<Shortcut> = [
        Shortcut(Shortcut.returnKey, modifiers: []), Shortcut(Shortcut.returnKey, modifiers: [.command]),
        Shortcut(Shortcut.returnKey, modifiers: [.shift]), Shortcut(Shortcut.returnKey, modifiers: [.option]),
        Shortcut(Shortcut.escapeKey, modifiers: []), Shortcut(Shortcut.upArrowKey, modifiers: []),
    ]

    /// No text field, page editor or terminal TextBox has the keyboard.
    public static let notTextInput = WhenClause.and([
        .not(.has(KeyContext.textInputFocus)), .not(.has("textBoxFocused")),
    ])

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
    /// keybindings.json). The Chrome tab keys go later (`tabSwitching(registry:)`).
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
