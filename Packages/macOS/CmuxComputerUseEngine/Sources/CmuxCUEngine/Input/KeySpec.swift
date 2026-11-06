// SPDX-License-Identifier: GPL-3.0-or-later
@preconcurrency import CoreGraphics
import Foundation

/// A key chord in xdotool syntax (`Return`, `super+c`, `ctrl+shift+Tab`,
/// `KP_0`), the syntax Codex Computer Use accepts, as a macOS virtual key
/// code and modifier flags.
struct KeySpec: Sendable, Equatable {
    var keyCode: CGKeyCode
    var flags: CGEventFlags

    enum ParseError: Error, CustomStringConvertible, Equatable {
        case empty
        case unknownKey(String)
        case unknownModifier(String)

        var description: String {
            switch self {
            case .empty: "no key given"
            case .unknownKey(let key): "unknown key \"\(key)\" (use xdotool names: Return, Tab, Escape, a, super+c, KP_0)"
            case .unknownModifier(let modifier): "unknown modifier \"\(modifier)\" (super, cmd, ctrl, alt, option, shift, fn)"
            }
        }
    }

    init(keyCode: CGKeyCode, flags: CGEventFlags = []) {
        self.keyCode = keyCode
        self.flags = flags
    }

    init(parsing text: String) throws {
        let parts = text.split(separator: "+", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        // "ctrl++" means ctrl and the plus key.
        var names = parts
        if text.hasSuffix("++") { names = Array(parts.dropLast(2)) + ["plus"] }
        guard let keyName = names.last, !keyName.isEmpty else { throw ParseError.empty }
        var flags: CGEventFlags = []
        for modifier in names.dropLast() {
            guard let flag = Self.modifiers[modifier.lowercased()] else { throw ParseError.unknownModifier(modifier) }
            flags.insert(flag)
        }
        guard let resolved = Self.code(for: keyName) else { throw ParseError.unknownKey(keyName) }
        keyCode = resolved.code
        self.flags = flags.union(resolved.flags)
    }

    static let modifiers: [String: CGEventFlags] = [
        "super": .maskCommand, "cmd": .maskCommand, "command": .maskCommand, "meta": .maskCommand,
        "ctrl": .maskControl, "control": .maskControl,
        "alt": .maskAlternate, "option": .maskAlternate, "opt": .maskAlternate,
        "shift": .maskShift, "fn": .maskSecondaryFn,
    ]

    static func code(for name: String) -> (code: CGKeyCode, flags: CGEventFlags)? {
        if let code = named[name] ?? named[name.lowercased()] { return (code, []) }
        if name.count == 1, let character = name.first {
            if let code = characters[character] { return (code, []) }
            let lower = Character(character.lowercased())
            if character.isUppercase, let code = characters[lower] { return (code, .maskShift) }
            if let (code, shifted) = shiftedCharacters[character] { return (code, shifted ? .maskShift : []) }
        }
        return nil
    }

    static let characters: [Character: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34,
        "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46,
        ".": 47, "`": 50, " ": 49,
    ]

    static let shiftedCharacters: [Character: (CGKeyCode, Bool)] = [
        "!": (18, true), "@": (19, true), "#": (20, true), "$": (21, true), "%": (23, true), "^": (22, true),
        "&": (26, true), "*": (28, true), "(": (25, true), ")": (29, true), "_": (27, true), "+": (24, true),
        "{": (33, true), "}": (30, true), "|": (42, true), ":": (41, true), "\"": (39, true), "<": (43, true),
        ">": (47, true), "?": (44, true), "~": (50, true),
    ]

    static let named: [String: CGKeyCode] = [
        "Return": 36, "return": 36, "Enter": 36, "enter": 36, "Tab": 48, "tab": 48, "space": 49, "Space": 49,
        "BackSpace": 51, "backspace": 51, "Delete": 117, "delete": 117, "Escape": 53, "escape": 53, "Esc": 53,
        "Left": 123, "Right": 124, "Down": 125, "Up": 126, "left": 123, "right": 124, "down": 125, "up": 126,
        "Home": 115, "End": 119, "Page_Up": 116, "Prior": 116, "Page_Down": 121, "Next": 121,
        "Insert": 114, "Help": 114,
        "F1": 122, "F2": 120, "F3": 99, "F4": 118, "F5": 96, "F6": 97, "F7": 98, "F8": 100, "F9": 101,
        "F10": 109, "F11": 103, "F12": 111, "F13": 105, "F14": 107, "F15": 113, "F16": 106,
        "KP_0": 82, "KP_1": 83, "KP_2": 84, "KP_3": 85, "KP_4": 86, "KP_5": 87, "KP_6": 88, "KP_7": 89,
        "KP_8": 91, "KP_9": 92, "KP_Decimal": 65, "KP_Multiply": 67, "KP_Add": 69, "KP_Divide": 75,
        "KP_Enter": 76, "KP_Subtract": 78, "KP_Equal": 81, "KP_Clear": 71,
        "minus": 27, "equal": 24, "plus": 24, "comma": 43, "period": 47, "slash": 44, "semicolon": 41,
        "apostrophe": 39, "bracketleft": 33, "bracketright": 30, "backslash": 42, "grave": 50,
        "Caps_Lock": 57, "VolumeUp": 72, "VolumeDown": 73, "Mute": 74,
    ]
}
