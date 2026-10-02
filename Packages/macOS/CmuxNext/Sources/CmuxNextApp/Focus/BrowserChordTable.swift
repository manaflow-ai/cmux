import AppKit
import CmuxNextActions

/// Chords a browser owns while a page, the address bar or the find bar has
/// the keyboard (plans/cmux-next/focus.md section 5, "Browser context").
///
/// The key router resolves a chord in this order: a cmux registry action
/// (catalog default or `cmux.json`), then, only when the registry has none,
/// the user's Ghostty keybinds for window, tab and split actions. In a
/// browser context that fallback is refused for every chord listed here,
/// because browsers give it a meaning users expect in a page:
/// Ghostty's default `super+[` (`goto_split:previous`) must not replace
/// Back. Chords cmux itself binds (Cmd-D split, Cmd-T new tab, Cmd-W close,
/// Cmd-1..9 tab select) are resolved by the registry before this table is
/// consulted, so cmux keeps them.
enum BrowserChordTable {
    private static let left = Shortcut.leftArrowKey
    private static let right = String(Character(UnicodeScalar(UInt32(NSRightArrowFunctionKey))!))
    private static let pageUp = String(Character(UnicodeScalar(UInt32(NSPageUpFunctionKey))!))
    private static let pageDown = String(Character(UnicodeScalar(UInt32(NSPageDownFunctionKey))!))

    /// Chrome for Mac shortcuts (support.google.com/chrome/answer/157179,
    /// "Mac keyboard shortcuts"), limited to Command and Control chords.
    static let chromeReserved: Set<Shortcut> = {
        var set: Set<Shortcut> = [
            // Navigation: Back, Forward.
            Shortcut("["), Shortcut("]"), Shortcut(left), Shortcut(right),
            // Reload, hard reload, stop.
            Shortcut("r"), Shortcut("r", modifiers: [.command, .shift]), Shortcut("."),
            // Address bar, new tab, reopen tab, close tab/window, new window, incognito.
            Shortcut("l"), Shortcut("t"), Shortcut("t", modifiers: [.command, .shift]), Shortcut("w"),
            Shortcut("w", modifiers: [.command, .shift]), Shortcut("n"), Shortcut("n", modifiers: [.command, .shift]),
            // Find, find next/previous, use selection for find.
            Shortcut("f"), Shortcut("g"), Shortcut("g", modifiers: [.command, .shift]), Shortcut("e"),
            // Bookmark, bookmark all tabs, bookmark bar, bookmark manager.
            Shortcut("d"), Shortcut("d", modifiers: [.command, .shift]), Shortcut("b", modifiers: [.command, .shift]),
            Shortcut("b", modifiers: [.command, .option]),
            // History, downloads, print, save, open file, view source, developer tools, JS console.
            Shortcut("y"), Shortcut("j", modifiers: [.command, .shift]), Shortcut("p"), Shortcut("s"), Shortcut("o"),
            Shortcut("u", modifiers: [.command, .option]), Shortcut("i", modifiers: [.command, .option]),
            Shortcut("j", modifiers: [.command, .option]), Shortcut("c", modifiers: [.command, .option]),
            // Zoom.
            Shortcut("="), Shortcut("+"), Shortcut("-"), Shortcut("0"),
            // Next/previous tab.
            Shortcut(right, modifiers: [.command, .option]), Shortcut(left, modifiers: [.command, .option]),
            Shortcut("]", modifiers: [.command, .shift]), Shortcut("[", modifiers: [.command, .shift]),
            Shortcut("\t", modifiers: [.control]), Shortcut("\t", modifiers: [.control, .shift]),
            Shortcut(pageDown, modifiers: [.control]), Shortcut(pageUp, modifiers: [.control]),
            // Edit chords a page or the address bar handles.
            Shortcut("a"), Shortcut("c"), Shortcut("v"), Shortcut("x"), Shortcut("z"),
            Shortcut("z", modifiers: [.command, .shift]), Shortcut("v", modifiers: [.command, .shift]),
            Shortcut("v", modifiers: [.command, .shift, .option]),
        ]
        // Select tab 1-8, last tab.
        for digit in 1...9 { set.insert(Shortcut(String(digit))) }
        return set
    }()

    /// Chrome's next/previous tab chords. cmux tabs are the browser's tabs,
    /// so in a browser context each one runs cmux's own next or previous
    /// tab action, whatever the user's Ghostty keybinds say (a terminal
    /// keeps its own keybinds, `ctrl+tab=next_tab` by default). The router
    /// consults this only when the registry has no action for the chord,
    /// so a cmux binding (Cmd-Opt-arrows focus a pane, Cmd-Shift-] is next
    /// tab already) wins.
    static let tabNavigation: [Shortcut: ActionID] = [
        Shortcut("\t", modifiers: [.control]): "nextSurface",
        Shortcut("\t", modifiers: [.control, .shift]): "prevSurface",
        Shortcut(pageDown, modifiers: [.control]): "nextSurface",
        Shortcut(pageUp, modifiers: [.control]): "prevSurface",
        Shortcut(right, modifiers: [.command, .option]): "nextSurface",
        Shortcut(left, modifiers: [.command, .option]): "prevSurface",
        Shortcut("]", modifiers: [.command, .shift]): "nextSurface",
        Shortcut("[", modifiers: [.command, .shift]): "prevSurface",
    ]

    /// Whether `event` is a chord Chrome defines.
    static func isChromeChord(_ event: NSEvent) -> Bool {
        shortcuts(of: event).contains { chromeReserved.contains($0) }
    }

    /// Actions whose chords act only in a browser context (user 2026-09-30,
    /// "consistency is most important"): page Back and Forward. Elsewhere
    /// their chords (Cmd-[ / Cmd-] by default, or the user's rebinding) do
    /// nothing: cmux consumes them, so neither a Ghostty keybind nor the
    /// shell gets them.
    static let browserOnlyActions: [ActionID] = ["browserBack", "browserForward"]

    /// Whether `event` is the effective chord of a browser-only action.
    static func isBrowserOnlyChord(_ event: NSEvent, registry: ActionRegistry) -> Bool {
        let chords = browserOnlyActions.compactMap(registry.effectiveShortcut(for:))
        return shortcuts(of: event).contains { chords.contains($0) }
    }

    /// The cmux tab action for a Chrome tab-switching chord, or nil.
    static func tabNavigationAction(for event: NSEvent) -> ActionID? {
        shortcuts(of: event).lazy.compactMap { tabNavigation[$0] }.first
    }

    /// Like `ActionRegistry.resolveShortcut`: the key as typed and its
    /// unshifted base (Cmd-Shift-[ arrives as "{", Ctrl-Shift-Tab as
    /// back-tab U+0019).
    private static func shortcuts(of event: NSEvent) -> [Shortcut] {
        guard event.type == .keyDown else { return [] }
        let keys = [event.charactersIgnoringModifiers, event.characters(byApplyingModifiers: [])].compactMap { $0 }
        return keys.map { Shortcut($0, modifiers: event.modifierFlags) }
    }

    /// Whether the focus target is browser content (page, address bar, find
    /// bar, docked DevTools).
    nonisolated static func isBrowserContext(_ resolved: FocusState.Resolved) -> Bool {
        switch resolved {
        case .browserPage, .addressBar, .findBar, .devTools: true
        default: false
        }
    }
}
