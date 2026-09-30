import AppKit
import CmuxNextActions

/// Chords a browser owns while a page, the address bar or the find bar has
/// the keyboard (plans/cmux-next/focus.md section 5, "Browser context").
///
/// The key router resolves a chord in this order: a cmux registry action
/// (catalog default or `cmux.json`), then, only when the registry has none,
/// the user's Ghostty keybinds for window, tab and split actions. In a
/// browser context that fallback is refused for every chord listed here,
/// because Chrome (and Safari) give it a meaning users expect in a page:
/// Ghostty's default `super+[` (`goto_split:previous`) must not replace
/// Back. Chords cmux itself binds (Cmd-D split, Cmd-T new tab, Cmd-W close,
/// Cmd-1..9 tab select) are resolved by the registry before this table is
/// consulted, so cmux keeps them.
enum BrowserChordTable {
    private static let left = Shortcut.leftArrowKey
    private static let right = String(Character(UnicodeScalar(UInt32(NSRightArrowFunctionKey))!))

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
            // Edit chords a page or the address bar handles.
            Shortcut("a"), Shortcut("c"), Shortcut("v"), Shortcut("x"), Shortcut("z"),
            Shortcut("z", modifiers: [.command, .shift]), Shortcut("v", modifiers: [.command, .shift]),
            Shortcut("v", modifiers: [.command, .shift, .option]),
        ]
        // Select tab 1-8, last tab.
        for digit in 1...9 { set.insert(Shortcut(String(digit))) }
        return set
    }()

    /// Whether `event` is a chord Chrome defines.
    static func isChromeChord(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        // Like `ActionRegistry.resolveShortcut`: the key as typed and its
        // unshifted base (Cmd-Shift-[ arrives as "{" on US layouts).
        let keys = [event.charactersIgnoringModifiers, event.characters(byApplyingModifiers: [])].compactMap { $0 }
        return keys.contains { chromeReserved.contains(Shortcut($0, modifiers: event.modifierFlags)) }
    }

    /// Whether the focus target is browser content (page, address bar, find bar).
    nonisolated static func isBrowserContext(_ resolved: FocusState.Resolved) -> Bool {
        switch resolved {
        case .browserPage, .addressBar, .findBar: true
        default: false
        }
    }
}
