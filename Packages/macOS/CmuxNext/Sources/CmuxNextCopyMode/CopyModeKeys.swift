/// Vim-style key table for terminal copy mode (the old app's keyboard copy
/// mode, same keys):
///
/// - h/j/k/l and arrows move the cursor, or the selection's moving end.
/// - 0 or ^ and $ go to the start and end of the line; gg and G to the top
///   and bottom; Home, End, Page Up and Page Down scroll or extend.
/// - Ctrl-U/D half page, Ctrl-B/F page, Ctrl-Y/E one line.
/// - v starts or clears a character selection, V a line selection; y copies
///   it and leaves; yy and Y copy lines. Digits are a count prefix.
/// - { and } jump between prompts; / searches, n and N step through matches.
/// - Esc and q leave. Command chords pass through to app shortcuts; every
///   other key is swallowed.
///
/// Key codes are macOS virtual key codes. `asciiCharacter` maps a key code
/// to its ASCII character for non-ASCII input sources, so h/j/k/l work under
/// a Korean or Russian layout.
public struct CopyModeKeys {
    let asciiCharacter: (UInt16) -> String?

    public init(asciiCharacter: @escaping (UInt16) -> String? = { _ in nil }) {
        self.asciiCharacter = asciiCharacter
    }

    /// Largest count prefix.
    public static let maxCount = 9_999

    public static func clampCount(_ value: Int) -> Int {
        min(max(value, 1), maxCount)
    }

    /// Command chords bypass copy mode so app shortcuts (Copy, the copy-mode
    /// toggle itself) still work.
    public static func bypassesForShortcut(_ modifiers: CopyModeModifiers) -> Bool {
        normalized(modifiers).contains(.command)
    }

    /// One key without pending state. `nil` when the key is not a command.
    public func action(
        keyCode: UInt16,
        charactersIgnoringModifiers: String?,
        modifiers: CopyModeModifiers,
        hasSelection: Bool
    ) -> CopyModeAction? {
        let key = Key(keyCode: keyCode, characters: charactersIgnoringModifiers, modifiers: modifiers,
                      asciiCharacter: asciiCharacter)
        let mods = key.modifiers, chars = key.chars, lower = key.lowercased

        if keyCode == KeyCode.escape { return .exit }
        switch keyCode {
        case KeyCode.upArrow: return .adjustSelection(.up)
        case KeyCode.downArrow: return .adjustSelection(.down)
        case KeyCode.leftArrow: return .adjustSelection(.left)
        case KeyCode.rightArrow: return .adjustSelection(.right)
        case KeyCode.pageUp: return hasSelection ? .adjustSelection(.pageUp) : .scrollPage(-1)
        case KeyCode.pageDown: return hasSelection ? .adjustSelection(.pageDown) : .scrollPage(1)
        case KeyCode.home: return hasSelection ? .adjustSelection(.home) : .scrollToTop
        case KeyCode.end: return hasSelection ? .adjustSelection(.end) : .scrollToBottom
        default: break
        }

        if mods == [.control] {
            switch true {
            case lower == "u" || chars == "\u{15}": return hasSelection ? .adjustSelection(.pageUp) : .scrollHalfPage(-1)
            case lower == "d" || chars == "\u{04}": return hasSelection ? .adjustSelection(.pageDown) : .scrollHalfPage(1)
            case lower == "b" || chars == "\u{02}": return hasSelection ? .adjustSelection(.pageUp) : .scrollPage(-1)
            case lower == "f" || chars == "\u{06}": return hasSelection ? .adjustSelection(.pageDown) : .scrollPage(1)
            case lower == "y" || chars == "\u{19}": return hasSelection ? .adjustSelection(.up) : .scrollLines(-1)
            case lower == "e" || chars == "\u{05}": return hasSelection ? .adjustSelection(.down) : .scrollLines(1)
            default: return nil
            }
        }

        guard mods.isEmpty || mods == [.shift] else { return nil }
        switch lower {
        case "q":
            return .exit
        case "v":
            if key.isUppercase { return .startLineSelection }
            return hasSelection ? .clearSelection : .startSelection
        case "y":
            if key.isUppercase, !hasSelection { return .copyLineAndExit }
            return hasSelection ? .copyAndExit : nil
        case "j": return .adjustSelection(.down)
        case "k": return .adjustSelection(.up)
        case "h": return .adjustSelection(.left)
        case "l": return .adjustSelection(.right)
        case "g":
            guard key.isUppercase else { return nil }
            return hasSelection ? .adjustSelection(.end) : .scrollToBottom
        case "0", "^":
            return .adjustSelection(.beginningOfLine)
        case "$", "4":
            guard chars == "$" || mods == [.shift] else { return nil }
            return .adjustSelection(.endOfLine)
        case "{", "[":
            guard chars == "{" || mods == [.shift] else { return nil }
            return .jumpToPrompt(-1)
        case "}", "]":
            guard chars == "}" || mods == [.shift] else { return nil }
            return .jumpToPrompt(1)
        case "/":
            return .startSearch
        case "n":
            return key.isUppercase ? .searchPrevious : .searchNext
        default:
            return nil
        }
    }

    /// One key with the session's pending state: count prefixes, `gg`, `yy`.
    public func resolve(
        keyCode: UInt16,
        charactersIgnoringModifiers: String?,
        modifiers: CopyModeModifiers,
        hasSelection: Bool,
        state: inout CopyModeInputState
    ) -> CopyModeResolution {
        let key = Key(keyCode: keyCode, characters: charactersIgnoringModifiers, modifiers: modifiers,
                      asciiCharacter: asciiCharacter)
        let mods = key.modifiers, lower = key.lowercased

        func perform(_ action: CopyModeAction) -> CopyModeResolution {
            let count = Self.clampCount(state.countPrefix ?? 1)
            state.reset()
            return .perform(action, count: count)
        }

        if keyCode == KeyCode.escape {
            state.reset()
            return .perform(.exit, count: 1)
        }
        if state.pendingYankLine {
            if lower == "y", mods.isEmpty || mods == [.shift] { return perform(.copyLineAndExit) }
            state.reset()
        }
        if state.pendingG {
            if lower == "g", mods.isEmpty, !key.isUppercase {
                return perform(hasSelection ? .adjustSelection(.home) : .scrollToTop)
            }
            state.reset()
        }
        if mods.isEmpty, let scalar = lower.unicodeScalars.first, scalar.isASCII, (48...57).contains(scalar.value) {
            let digit = Int(scalar.value - 48)
            if digit != 0 {
                state.countPrefix = Self.clampCount((state.countPrefix ?? 0) * 10 + digit)
                return .consume
            }
            // A leading 0 is "start of line"; after digits it extends the count.
            if let count = state.countPrefix {
                state.countPrefix = Self.clampCount(count * 10)
                return .consume
            }
        }
        if !hasSelection, lower == "y", key.isUppercase { return perform(.copyLineAndExit) }
        if lower == "g", key.isUppercase { return perform(hasSelection ? .adjustSelection(.end) : .scrollToBottom) }
        if !hasSelection, lower == "y", mods.isEmpty {
            state.pendingYankLine = true
            return .consume
        }
        if lower == "g", mods.isEmpty {
            state.pendingG = true
            return .consume
        }
        guard let action = self.action(keyCode: keyCode, charactersIgnoringModifiers: charactersIgnoringModifiers,
                                       modifiers: modifiers, hasSelection: hasSelection) else {
            state.reset()
            return .consume
        }
        return perform(action)
    }

    // MARK: Helpers

    private static func normalized(_ modifiers: CopyModeModifiers) -> CopyModeModifiers {
        modifiers.subtracting([.numericPad, .function, .capsLock])
    }

    /// macOS virtual key codes (Carbon `kVK_*`).
    enum KeyCode {
        static let escape: UInt16 = 53
        static let upArrow: UInt16 = 126
        static let downArrow: UInt16 = 125
        static let leftArrow: UInt16 = 123
        static let rightArrow: UInt16 = 124
        static let pageUp: UInt16 = 116
        static let pageDown: UInt16 = 121
        static let home: UInt16 = 115
        static let end: UInt16 = 119
    }

    /// One key event, normalized for matching.
    private struct Key {
        /// Modifiers without numeric pad, function, and Caps Lock.
        let modifiers: CopyModeModifiers
        /// The first character, mapped to ASCII through the provider when the
        /// layout reports a non-ASCII one.
        let chars: String
        let lowercased: String
        /// Shift alone, or an ASCII capital without Caps Lock.
        let isUppercase: Bool

        init(keyCode: UInt16, characters: String?, modifiers raw: CopyModeModifiers,
             asciiCharacter: (UInt16) -> String?) {
            modifiers = CopyModeKeys.normalized(raw)
            let first = characters?.unicodeScalars.first.map { String($0) } ?? ""
            if first.allSatisfy(\.isASCII) {
                chars = first
            } else if let ascii = asciiCharacter(keyCode)?.unicodeScalars.first {
                chars = String(ascii)
            } else {
                chars = first
            }
            lowercased = chars.lowercased()
            if modifiers == [.shift] {
                isUppercase = true
            } else if raw.contains(.capsLock) {
                isUppercase = false
            } else if let scalar = chars.unicodeScalars.first, scalar.isASCII {
                isUppercase = (65...90).contains(scalar.value)
            } else {
                isUppercase = false
            }
        }
    }
}
