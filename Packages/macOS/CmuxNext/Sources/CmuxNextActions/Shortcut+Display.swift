import AppKit

extension Shortcut {
    // Key-equivalent characters for non-printing keys (NSMenuItem semantics).
    public nonisolated static let upArrowKey = String(Character(UnicodeScalar(UInt32(NSUpArrowFunctionKey))!))
    public nonisolated static let downArrowKey = String(Character(UnicodeScalar(UInt32(NSDownArrowFunctionKey))!))
    public nonisolated static let leftArrowKey = String(Character(UnicodeScalar(UInt32(NSLeftArrowFunctionKey))!))
    public nonisolated static let rightArrowKey = String(Character(UnicodeScalar(UInt32(NSRightArrowFunctionKey))!))
    public nonisolated static let returnKey = "\r"
    public nonisolated static let tabKey = "\t"
    public nonisolated static let escapeKey = "\u{1B}"
    public nonisolated static let deleteKey = "\u{8}"
    public nonisolated static let spaceKey = " "

    /// Modifier glyphs in macOS menu order: control, option, shift, command.
    public var modifierGlyphs: [String] {
        var glyphs: [String] = []
        if modifiers.contains(.control) { glyphs.append("⌃") }
        if modifiers.contains(.option) { glyphs.append("⌥") }
        if modifiers.contains(.shift) { glyphs.append("⇧") }
        if modifiers.contains(.command) { glyphs.append("⌘") }
        return glyphs
    }

    /// Glyph for the key itself, as menus show it.
    public var keyGlyph: String {
        switch key {
        case Self.upArrowKey: "↑"
        case Self.downArrowKey: "↓"
        case Self.leftArrowKey: "←"
        case Self.rightArrowKey: "→"
        case Self.returnKey: "↩"
        case Self.tabKey: "⇥"
        case Self.escapeKey: "⎋"
        case Self.deleteKey, "\u{7F}": "⌫"
        case Self.spaceKey: String(localized: "shortcut.key.space", defaultValue: "Space", bundle: .module)
        default: key.uppercased()
        }
    }

    /// Separate keycaps, for rendering one badge per key: `["⇧", "⌘", "P"]`.
    public var keycaps: [String] { modifierGlyphs + [keyGlyph] }

    /// Compact menu-style text: `⇧⌘P`.
    public var displayString: String { keycaps.joined() }

    /// Words that let a search for "cmd shift p" or "command d" find this
    /// shortcut.
    public var searchTokens: [String] {
        var tokens: [String] = []
        if modifiers.contains(.control) { tokens += ["ctrl", "control", "⌃"] }
        if modifiers.contains(.option) { tokens += ["opt", "option", "alt", "⌥"] }
        if modifiers.contains(.shift) { tokens += ["shift", "⇧"] }
        if modifiers.contains(.command) { tokens += ["cmd", "command", "⌘"] }
        tokens.append(keyWord)
        tokens.append(displayString)
        return tokens
    }

    private var keyWord: String {
        switch key {
        case Self.upArrowKey: "up"
        case Self.downArrowKey: "down"
        case Self.leftArrowKey: "left"
        case Self.rightArrowKey: "right"
        case Self.returnKey: "return enter"
        case Self.tabKey: "tab"
        case Self.escapeKey: "escape"
        case Self.deleteKey, "\u{7F}": "delete"
        case Self.spaceKey: "space"
        default: key
        }
    }
}
