import AppKit
import CoreGraphics
import CmuxBrowser
import Foundation

struct SyntheticKeySpecification {
    let storedKey: String
    let keyCode: UInt16
    let modifierFlags: NSEvent.ModifierFlags
    let characters: String
    let charactersIgnoringModifiers: String
}

enum SyntheticKeyEventFactory {
    static func parseShortcutCombo(_ combo: String) -> SyntheticKeySpecification? {
        let raw = combo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }

        let parts = raw
            .split(separator: "+")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }

        var flags: NSEvent.ModifierFlags = []
        var keyToken: String?
        for part in parts {
            if let flag = modifierFlag(named: part) {
                flags.insert(flag)
            } else if keyToken == nil {
                keyToken = part
            } else {
                return nil
            }
        }
        guard let keyToken else { return nil }
        return specification(key: keyToken, modifierFlags: flags)
    }

    static func specification(
        key: String,
        modifierNames: [String]
    ) -> SyntheticKeySpecification? {
        var flags: NSEvent.ModifierFlags = []
        for name in modifierNames {
            guard let flag = modifierFlag(named: name) else { return nil }
            flags.insert(flag)
        }
        return specification(key: key, modifierFlags: flags)
    }

    /// Resolves the canonical browser automation key vocabulary into the
    /// AppKit key specification used by the native WebKit input seam.
    ///
    /// Browser automation keys are expressed with W3C/Playwright names,
    /// whereas the CGEvent factory uses macOS virtual-key names. Keeping this
    /// conversion beside the existing factory makes mobile replay and socket
    /// automation share one native mapping instead of maintaining two event
    /// pipelines.
    static func specification(forBrowserEvent event: BrowserKeyboardEvent) -> SyntheticKeySpecification? {
        guard let nativeKey = event.nativeKey else { return nil }
        return specification(forBrowserNativeKey: nativeKey)
    }

    /// Converts the browser package's platform-neutral descriptor into the
    /// AppKit representation consumed by CGEvent construction.
    static func specification(
        forBrowserNativeKey key: BrowserKeyboardNativeKey,
        additionalModifierFlags: NSEvent.ModifierFlags = []
    ) -> SyntheticKeySpecification {
        let flags = appKitModifierFlags(for: key.modifiers).union(additionalModifierFlags)

        return SyntheticKeySpecification(
            storedKey: key.charactersIgnoringModifiers ?? "",
            keyCode: key.keyCode,
            modifierFlags: flags,
            characters: key.characters ?? "",
            charactersIgnoringModifiers: key.charactersIgnoringModifiers ?? ""
        )
    }

    /// Converts the browser package's modifier bitset into AppKit flags.
    static func appKitModifierFlags(
        for modifiers: BrowserKeyboardNativeModifiers
    ) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.control) { flags.insert(.control) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.numericPad) { flags.insert(.numericPad) }
        if modifiers.contains(.capsLock) { flags.insert(.capsLock) }
        if modifiers.contains(.function) { flags.insert(.function) }
        return flags
    }

    static func specification(forASCIICharacter character: Character) -> SyntheticKeySpecification? {
        switch character {
        case "\n", "\r": return specification(key: "return", modifierFlags: [])
        case "\t": return specification(key: "tab", modifierFlags: [])
        case " ": return specification(key: "space", modifierFlags: [])
        default: break
        }

        let shiftedSymbols: [Character: Character] = [
            "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
            "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`",
        ]
        let requiresShift = character.isUppercase || shiftedSymbols[character] != nil
        let base = shiftedSymbols[character].map(String.init) ?? String(character).lowercased()
        guard var result = specification(
            key: base,
            modifierFlags: requiresShift ? [.shift] : []
        ) else { return nil }
        result = SyntheticKeySpecification(
            storedKey: result.storedKey,
            keyCode: result.keyCode,
            modifierFlags: result.modifierFlags,
            characters: String(character),
            charactersIgnoringModifiers: String(character)
        )
        return result
    }

    /// Builds an `NSEvent` backed by a real `CGEvent` so WebKit text input can
    /// safely interpret it. Callers choose their own direct delivery target.
    static func keyEvent(
        specification: SyntheticKeySpecification,
        keyDown: Bool,
        timestamp: TimeInterval,
        characters: String? = nil
    ) -> NSEvent? {
        guard let cgEvent = CGEvent(
            keyboardEventSource: nil,
            virtualKey: specification.keyCode,
            keyDown: keyDown
        ) else { return nil }
        cgEvent.flags = cgFlags(specification.modifierFlags)
        cgEvent.timestamp = CGEventTimestamp(timestamp * 1_000_000_000)
        if let characters {
            var utf16 = Array(characters.utf16)
            cgEvent.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        }
        return NSEvent(cgEvent: cgEvent)
    }

    private static func specification(
        key rawKey: String,
        modifierFlags: NSEvent.ModifierFlags
    ) -> SyntheticKeySpecification? {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return nil }

        let storedKey: String
        let keyCode: UInt16
        let charactersIgnoringModifiers: String
        switch key {
        case "left", "arrowleft": (storedKey, keyCode) = ("\u{F702}", 123)
        case "right", "arrowright": (storedKey, keyCode) = ("\u{F703}", 124)
        case "down", "arrowdown": (storedKey, keyCode) = ("\u{F701}", 125)
        case "up", "arrowup": (storedKey, keyCode) = ("\u{F700}", 126)
        case "enter", "return": (storedKey, keyCode) = ("\r", 36)
        case "tab": (storedKey, keyCode) = ("\t", 48)
        case "escape", "esc": (storedKey, keyCode) = ("\u{1b}", 53)
        case "delete", "backspace": (storedKey, keyCode) = ("\u{8}", 51)
        case "forward_delete": (storedKey, keyCode) = ("\u{f728}", 117)
        case "space": (storedKey, keyCode) = (" ", 49)
        case "home": (storedKey, keyCode) = ("\u{F729}", 115)
        case "end": (storedKey, keyCode) = ("\u{F72B}", 119)
        case "page_up": (storedKey, keyCode) = ("\u{F72C}", 116)
        case "page_down": (storedKey, keyCode) = ("\u{F72D}", 121)
        case "insert": (storedKey, keyCode) = ("\u{F727}", 114)
        case "clear": (storedKey, keyCode) = ("\u{F739}", 71)
        case "shift_left": (storedKey, keyCode) = ("\u{F700}", 56)
        case "shift_right": (storedKey, keyCode) = ("\u{F700}", 60)
        case "control_left": (storedKey, keyCode) = ("\u{F701}", 59)
        case "control_right": (storedKey, keyCode) = ("\u{F701}", 62)
        case "option_left": (storedKey, keyCode) = ("\u{F702}", 58)
        case "option_right": (storedKey, keyCode) = ("\u{F702}", 61)
        case "command_left": (storedKey, keyCode) = ("\u{F703}", 55)
        case "command_right": (storedKey, keyCode) = ("\u{F703}", 54)
        case "num_divide": (storedKey, keyCode) = ("/", 75)
        case "num_multiply": (storedKey, keyCode) = ("*", 67)
        case "num_minus": (storedKey, keyCode) = ("-", 78)
        case "num_plus": (storedKey, keyCode) = ("+", 69)
        case "num_decimal": (storedKey, keyCode) = (".", 65)
        case "f1": (storedKey, keyCode) = ("\u{F704}", 122)
        case "f2": (storedKey, keyCode) = ("\u{F705}", 120)
        case "f3": (storedKey, keyCode) = ("\u{F706}", 99)
        case "f4": (storedKey, keyCode) = ("\u{F707}", 118)
        case "f5": (storedKey, keyCode) = ("\u{F708}", 96)
        case "f6": (storedKey, keyCode) = ("\u{F709}", 97)
        case "f7": (storedKey, keyCode) = ("\u{F70A}", 98)
        case "f8": (storedKey, keyCode) = ("\u{F70B}", 100)
        case "f9": (storedKey, keyCode) = ("\u{F70C}", 101)
        case "f10": (storedKey, keyCode) = ("\u{F70D}", 109)
        case "f11": (storedKey, keyCode) = ("\u{F70E}", 103)
        case "f12": (storedKey, keyCode) = ("\u{F70F}", 111)
        default:
            guard key.count == 1, let resolved = Self.keyCode(for: key) else { return nil }
            storedKey = key
            keyCode = resolved
        }

        if modifierFlags.contains(.control),
           storedKey.count == 1,
           let scalar = storedKey.unicodeScalars.first,
           scalar.isASCII,
           scalar.value >= 97, scalar.value <= 122 {
            charactersIgnoringModifiers = String(UnicodeScalar(scalar.value - 96)!)
        } else {
            charactersIgnoringModifiers = storedKey
        }
        return SyntheticKeySpecification(
            storedKey: storedKey,
            keyCode: keyCode,
            modifierFlags: modifierFlags,
            characters: charactersIgnoringModifiers,
            charactersIgnoringModifiers: charactersIgnoringModifiers
        )
    }

    private static func modifierFlag(named rawName: String) -> NSEvent.ModifierFlags? {
        switch rawName.lowercased() {
        case "cmd", "command", "super": return .command
        case "ctrl", "control": return .control
        case "opt", "option", "alt": return .option
        case "shift": return .shift
        default: return nil
        }
    }

    private static func cgFlags(_ modifiers: NSEvent.ModifierFlags) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.capsLock) { flags.insert(.maskAlphaShift) }
        if modifiers.contains(.function) { flags.insert(.maskSecondaryFn) }
        if modifiers.contains(.numericPad) { flags.insert(.maskNumericPad) }
        return flags
    }

    private static func keyCode(for key: String) -> UInt16? {
        switch key {
        case "a": 0
        case "s": 1
        case "d": 2
        case "f": 3
        case "h": 4
        case "g": 5
        case "z": 6
        case "x": 7
        case "c": 8
        case "v": 9
        case "b": 11
        case "q": 12
        case "w": 13
        case "e": 14
        case "r": 15
        case "y": 16
        case "t": 17
        case "1": 18
        case "2": 19
        case "3": 20
        case "4": 21
        case "6": 22
        case "5": 23
        case "=": 24
        case "9": 25
        case "7": 26
        case "-": 27
        case "8": 28
        case "0": 29
        case "]": 30
        case "o": 31
        case "u": 32
        case "[": 33
        case "i": 34
        case "p": 35
        case "l": 37
        case "j": 38
        case "'": 39
        case "k": 40
        case ";": 41
        case "\\": 42
        case ",": 43
        case "/": 44
        case "n": 45
        case "m": 46
        case ".": 47
        case "`": 50
        default: nil
        }
    }
}
