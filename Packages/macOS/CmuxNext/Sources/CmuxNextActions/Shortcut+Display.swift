import AppKit

extension Shortcut {
    // Key-equivalent characters for non-printing keys (NSMenuItem semantics).
    public nonisolated static let upArrowKey = String(Character(UnicodeScalar(UInt32(NSUpArrowFunctionKey)) ?? UnicodeScalar(0)))
    public nonisolated static let downArrowKey = String(Character(UnicodeScalar(UInt32(NSDownArrowFunctionKey)) ?? UnicodeScalar(0)))
    public nonisolated static let leftArrowKey = String(Character(UnicodeScalar(UInt32(NSLeftArrowFunctionKey)) ?? UnicodeScalar(0)))
    public nonisolated static let rightArrowKey = String(Character(UnicodeScalar(UInt32(NSRightArrowFunctionKey)) ?? UnicodeScalar(0)))
    public nonisolated static let returnKey = "\r"
    public nonisolated static let tabKey = "\t"
    public nonisolated static let escapeKey = "\u{1B}"
    public nonisolated static let deleteKey = "\u{8}"
    public nonisolated static let spaceKey = " "
    public nonisolated static let forwardDeleteKey = functionKey(NSDeleteFunctionKey)
    public nonisolated static let homeKey = functionKey(NSHomeFunctionKey)
    public nonisolated static let endKey = functionKey(NSEndFunctionKey)
    public nonisolated static let pageUpKey = functionKey(NSPageUpFunctionKey)
    public nonisolated static let pageDownKey = functionKey(NSPageDownFunctionKey)
    public nonisolated static let clearKey = functionKey(NSClearLineFunctionKey)

    private nonisolated static func functionKey(_ code: Int) -> String {
        String(Character(UnicodeScalar(UInt32(code)) ?? UnicodeScalar(0)))
    }

    /// The function key's number (F1 is 1) when `key` is one of F1 to F35.
    private var functionKeyNumber: Int? {
        guard key.unicodeScalars.count == 1, let scalar = key.unicodeScalars.first else { return nil }
        let value = Int(scalar.value)
        guard value >= NSF1FunctionKey, value <= NSF35FunctionKey else { return nil }
        return value - NSF1FunctionKey + 1
    }

    /// Modifier glyphs in macOS menu order: control, option, shift, command.
    public var modifierGlyphs: [String] {
        var glyphs: [String] = []
        if modifiers.contains(.control) { glyphs.append("⌃") }
        if modifiers.contains(.option) { glyphs.append("⌥") }
        if modifiers.contains(.shift) { glyphs.append("⇧") }
        if modifiers.contains(.command) { glyphs.append("⌘") }
        return glyphs
    }

    /// Glyph for the key itself, as macOS menus show it. Every key AppKit names by a
    /// private-use character (NSEvent's function keys: Home, Page Up, F5) gets its menu
    /// glyph or name here: drawn as itself, the private-use character is a box or nothing.
    public var keyGlyph: String {
        if let number = functionKeyNumber { return "F\(number)" }
        return switch key {
        case Self.upArrowKey: "↑"
        case Self.downArrowKey: "↓"
        case Self.leftArrowKey: "←"
        case Self.rightArrowKey: "→"
        case Self.returnKey: "↩"
        case Self.tabKey: "⇥"
        case Self.escapeKey: "⎋"
        case Self.deleteKey, "\u{7F}": "⌫"
        case Self.forwardDeleteKey: "⌦"
        case Self.homeKey: "↖"
        case Self.endKey: "↘"
        case Self.pageUpKey: "⇞"
        case Self.pageDownKey: "⇟"
        case Self.clearKey: "⌧"
        case Self.spaceKey: String(localized: "shortcut.key.space", defaultValue: "Space", bundle: .localizedModule)
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
        case Self.deleteKey, "\u{7F}": "delete backspace"
        case Self.forwardDeleteKey: "forward delete del"
        case Self.homeKey: "home"
        case Self.endKey: "end"
        case Self.pageUpKey: "page up pgup"
        case Self.pageDownKey: "page down pgdn"
        case Self.clearKey: "clear"
        default: functionKeyNumber.map { "f\($0)" } ?? key
        }
    }
}
