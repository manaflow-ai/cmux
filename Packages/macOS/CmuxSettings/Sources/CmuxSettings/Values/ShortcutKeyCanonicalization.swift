import Foundation

/// Returns the canonical key for a newly recorded macOS key event.
///
/// macOS reports the shifted glyph in `charactersIgnoringModifiers` for
/// punctuation keys (`<`, `>`, `{`, …). cmux stores the physical base key and
/// the Shift modifier separately so recording, conflict detection, menus, and
/// runtime matching all describe the same keystroke.
public func recordedShortcutKey(
    keyCode: UInt16,
    charactersIgnoringModifiers: String?
) -> String? {
    if let physicalKey = physicalBaseShortcutKey(for: keyCode) {
        return physicalKey
    }

    guard let characters = charactersIgnoringModifiers?.lowercased(),
          !characters.isEmpty,
          characters.unicodeScalars.allSatisfy({
              !CharacterSet.controlCharacters.contains($0)
          }) else {
        return nil
    }
    return characters
}

/// Normalizes an already stored key when its recording-time key code is
/// available. Hand-written bindings without a key code retain their logical
/// key so non-US layouts remain configurable.
public func canonicalShortcutKey(_ key: String, keyCode: UInt16?) -> String {
    if key.lowercased().hasPrefix("media.") {
        return key
    }
    guard let keyCode,
          let physicalKey = physicalBaseShortcutKey(for: keyCode) else {
        return key.lowercased()
    }
    return physicalKey
}

private func physicalBaseShortcutKey(for keyCode: UInt16) -> String? {
    switch keyCode {
    case 36, 76: return "\r"
    case 48: return "\t"
    case 49: return "space"
    case 18: return "1"
    case 19: return "2"
    case 20: return "3"
    case 21: return "4"
    case 23: return "5"
    case 22: return "6"
    case 26: return "7"
    case 28: return "8"
    case 25: return "9"
    case 29: return "0"
    // Control-modified letter events can expose the control character in
    // `charactersIgnoringModifiers` (for example, Ctrl-F is U+0006). Use the
    // physical ANSI key so the recorder can still persist the intended letter.
    case 0: return "a"
    case 1: return "s"
    case 2: return "d"
    case 3: return "f"
    case 4: return "h"
    case 5: return "g"
    case 6: return "z"
    case 7: return "x"
    case 8: return "c"
    case 9: return "v"
    case 11: return "b"
    case 12: return "q"
    case 13: return "w"
    case 14: return "e"
    case 15: return "r"
    case 16: return "y"
    case 17: return "t"
    case 31: return "o"
    case 32: return "u"
    case 34: return "i"
    case 35: return "p"
    case 37: return "l"
    case 38: return "j"
    case 40: return "k"
    case 45: return "n"
    case 46: return "m"
    case 24: return "="
    case 27: return "-"
    case 30: return "]"
    case 33: return "["
    case 39: return "'"
    case 41: return ";"
    case 42: return "\\"
    case 43: return ","
    case 44: return "/"
    case 47: return "."
    case 50: return "`"
    case 123: return "←"
    case 124: return "→"
    case 125: return "↓"
    case 126: return "↑"
    case 122: return "f1"
    case 120: return "f2"
    case 99: return "f3"
    case 118: return "f4"
    case 96: return "f5"
    case 97: return "f6"
    case 98: return "f7"
    case 100: return "f8"
    case 101: return "f9"
    case 109: return "f10"
    case 103: return "f11"
    case 111: return "f12"
    case 105: return "f13"
    case 107: return "f14"
    case 113: return "f15"
    case 106: return "f16"
    case 64: return "f17"
    case 79: return "f18"
    case 80: return "f19"
    case 90: return "f20"
    default: return nil
    }
}
