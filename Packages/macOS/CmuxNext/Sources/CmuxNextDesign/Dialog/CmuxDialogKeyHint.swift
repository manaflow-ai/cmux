public import AppKit

/// The key that presses one dialog button, as the button shows it (u2647: every
/// dialog button says which key presses it, "Cancel esc", "Change return", "Don't Save ⌘D").
///
/// A hint is derived from the same rules that answer the keys
/// (``CmuxDialogKeys/hint(for:in:)``), so a button never shows a key that does not
/// press it: `CmuxDialogKeys.action(for: hint.key, modifiers: hint.modifiers, in: spec)`
/// is always `.press(button.id)`.
public nonisolated enum CmuxDialogKeyHint: Equatable, Sendable {
    /// Return presses the button (the dialog's default button).
    case `return`
    /// Escape presses the button (the dialog's cancel button).
    case escape
    /// Command plus this lowercase character presses the button.
    case command(Character)

    /// The keycap text: `return`, `esc` (as a Mac keyboard prints them; Lawrence 2026-11-09, Leo 2026-11-22), `⌘D`.
    public var glyph: String {
        switch self {
        case .return: KeycapLegend.legend("↩")
        case .escape: KeycapLegend.legend("⎋")
        case .command(let character): "⌘" + character.uppercased()
        }
    }

    /// The key as VoiceOver reads it ("Return", "Escape", "Command-D").
    public var spokenName: String {
        switch self {
        case .return: CmuxDialogStrings.keyReturn
        case .escape: CmuxDialogStrings.keyEscape
        case .command(let character): CmuxDialogStrings.keyCommand(character.uppercased())
        }
    }

    /// The dialog key this hint names, for ``CmuxDialogKeys/action(for:modifiers:in:)``.
    public var key: CmuxDialogKeys.Key {
        switch self {
        case .return: .return
        case .escape: .escape
        case .command(let character): .character(character)
        }
    }

    /// The modifiers held with ``key``.
    public var modifiers: CmuxDialogKeys.Modifiers {
        if case .command = self { return .command }
        return []
    }

    /// The button key equivalent that presses it (`NSButton.keyEquivalent`).
    public var keyEquivalent: String {
        switch self {
        case .return: "\r"
        case .escape: "\u{1b}"
        case .command(let character): String(character)
        }
    }

    /// The modifier mask held with ``keyEquivalent``.
    public var modifierMask: NSEvent.ModifierFlags {
        if case .command = self { return .command }
        return []
    }

    /// `title` then this keycap, the keycap smaller and in `hintColor` (default the secondary text
    /// color), as macOS menus draw their keys. Call inside the view's theme scope (`performWithTheme`).
    @MainActor
    public func attributedTitle(_ title: String, font: NSFont, color: NSColor, hintColor: NSColor? = nil) -> NSAttributedString {
        let text = NSMutableAttributedString(string: title, attributes: [.foregroundColor: color, .font: font])
        text.append(NSAttributedString(string: "  " + glyph, attributes: [
            .foregroundColor: hintColor ?? Palette.textSecondary,
            .font: Typography.caption,
        ]))
        return text
    }
}

/// What a keycap prints, as a Mac keyboard labels its keys: modifiers keep their glyphs (⌘ ⌥ ⌃ ⇧), the
/// named keys read as words ("return", "tab", "esc", "delete"), every other key as it is. Every keycap in
/// the app (palette rows and footer, dialogs, tooltips) prints through it. Leo 2026-11-22: "this command
/// palette's icons are really bad and not even properly depicting the keys"; a lone ↩ or ⇥ on a small cap
/// read as an arrow, not a key (design/palette-keycaps-gallery.html).
public nonisolated enum KeycapLegend {
    /// The legend for one key: `"↩"` and `"\r"` print "return", `"⇥"` "tab", `"⎋"` "esc", `"⌫"` "delete".
    public static func legend(_ key: String) -> String {
        switch key {
        case "↩", "⏎", "↵", "⌅", "\r": "return"
        case "⇥", "\t": "tab"
        case "⎋", "Esc", "ESC", "\u{1B}": "esc"
        case "⌫", "⌦", "\u{8}", "\u{7F}": "delete"
        default: key
        }
    }

    /// One keycap's text for a whole shortcut as menus write it (`"⌘↩"`, `"⇧⌘P"`): each named key as its
    /// word, a space between the modifiers and a word ("⌘ return"), the rest unchanged.
    public static func text(_ shortcut: String) -> String {
        guard legend(shortcut) == shortcut else { return legend(shortcut) }
        var out = ""
        for character in shortcut {
            let word = legend(String(character))
            if word != String(character), !out.isEmpty, !out.hasSuffix(" ") { out += " " }
            out += word
        }
        return out
    }

    /// Whether `key` is a modifier's glyph.
    public static func isModifier(_ key: String) -> Bool {
        ["⌃", "⌥", "⇧", "⌘", "fn"].contains(key)
    }

    /// `keys` split into the strokes pressed one after another: a stroke runs through its modifiers to its
    /// first other key, so `["⌘", "J", "S"]` (the chord ⌘J then S) is `[["⌘", "J"], ["S"]]` and
    /// `["⇧", "⌘", "P"]` one stroke.
    public static func strokes(_ keys: [String]) -> [[String]] {
        var strokes: [[String]] = []
        var current: [String] = []
        for key in keys {
            current.append(key)
            if !isModifier(key) {
                strokes.append(current)
                current = []
            }
        }
        if !current.isEmpty { strokes.append(current) }
        return strokes
    }
}
