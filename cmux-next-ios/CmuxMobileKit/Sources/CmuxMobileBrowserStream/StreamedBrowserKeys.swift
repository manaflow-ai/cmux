import CoreGraphics
import Foundation

/// The keys a phone keyboard lacks, on the bar above it in a streamed browser tab, and
/// what each sends to the Mac's page (`cmux.rb/1` key events).
public enum StreamedBrowserKey: String, CaseIterable, Sendable {
    case escape, tab, left, up, down, right, selectAll, copy, cut, undo

    /// The bar's label: an SF Symbol, or a short text.
    public var symbol: String {
        switch self {
        case .escape: "escape"
        case .tab: "arrow.right.to.line"
        case .left: "arrow.left"
        case .up: "arrow.up"
        case .down: "arrow.down"
        case .right: "arrow.right"
        case .selectAll: "selection.pin.in.out"
        case .copy: "doc.on.doc"
        case .cut: "scissors"
        case .undo: "arrow.uturn.backward"
        }
    }

    public var title: String {
        switch self {
        case .escape: String(localized: "Escape")
        case .tab: String(localized: "Tab")
        case .left: String(localized: "Left Arrow")
        case .up: String(localized: "Up Arrow")
        case .down: String(localized: "Down Arrow")
        case .right: String(localized: "Right Arrow")
        case .selectAll: String(localized: "Select All")
        case .copy: String(localized: "Copy")
        case .cut: String(localized: "Cut")
        case .undo: String(localized: "Undo")
        }
    }

    /// The key down and up the Mac's page gets.
    public func events(_ wire: RemoteBrowserWire) -> [Data] {
        let (code, key, text, modifiers, commands): (String, String, String, RemoteBrowserWire.Modifiers, [String]) =
            switch self {
            case .escape: ("Escape", "Escape", "", [], [])
            case .tab: ("Tab", "Tab", "\t", [], [])
            case .left: ("ArrowLeft", "ArrowLeft", "", [], [])
            case .up: ("ArrowUp", "ArrowUp", "", [], [])
            case .down: ("ArrowDown", "ArrowDown", "", [], [])
            case .right: ("ArrowRight", "ArrowRight", "", [], [])
            case .selectAll: ("KeyA", "a", "", .command, ["SelectAll"])
            case .copy: ("KeyC", "c", "", .command, ["Copy"])
            case .cut: ("KeyX", "x", "", .command, ["Cut"])
            case .undo: ("KeyZ", "z", "", .command, ["Undo"])
            }
        return [wire.key(code, key: key, text: text, down: true, modifiers: modifiers, editCommands: commands),
                wire.key(code, key: key, text: text, down: false, modifiers: modifiers)]
    }

    /// What the software keyboard's own keys send (`UIKeyInput.insertText`): Return and
    /// Tab as keys, anything else as committed text (emoji, dictation, other scripts).
    public static func typed(_ text: String, wire: RemoteBrowserWire) -> [Data] {
        switch text {
        case "\n", "\r": [wire.key("Enter", key: "Enter", text: "\r", down: true), wire.key("Enter", key: "Enter", text: "\r", down: false)]
        case "\t": tab.events(wire)
        case "": []
        default: [wire.commit(text)]
        }
    }

    /// How much of a page of `page` (in window coordinates) the keyboard at
    /// `keyboard` covers: the page lays out in what is left, above the keyboard.
    public static func covered(page: CGRect, keyboard: CGRect?) -> CGFloat {
        guard let keyboard, !keyboard.isEmpty, keyboard.minY < page.maxY else { return 0 }
        return min(page.height, page.maxY - max(keyboard.minY, page.minY))
    }
}

/// The page's focused field, as the Mac's browser host reports it (`rb.text_input`).
public struct StreamedBrowserField: Equatable, Sendable {
    /// `text`, `search`, `email`, `url`, `password`, `number`, `telephone`,
    /// `text_area`, `content_editable`, `date_time` (never `none`).
    public var inputType: String
    /// The caret in the page's CSS pixels, when there is one.
    public var caret: CGRect?

    /// The field of an `rb.text_input` message; nil when nothing takes text.
    public init?(json: [String: Any]) {
        guard let type = json["input_type"] as? String, type != "none" else { return nil }
        inputType = type
        if let c = json["caret"] as? [String: Any], let x = c["x"] as? Double, let y = c["y"] as? Double,
           let w = c["width"] as? Double, let h = c["height"] as? Double {
            caret = CGRect(x: x, y: y, width: w, height: h)
        } else {
            caret = nil
        }
    }
}

/// A key of a hardware keyboard attached to the phone that the software keyboard path
/// never sees (arrows, Escape, Home/End, forward Delete) or a shortcut (Command or
/// Control held): what the Mac's page gets.
public struct StreamedHardwareKey: Equatable, Sendable {
    public var code: String
    public var key: String
    public var modifiers: RemoteBrowserWire.Modifiers
    public var editCommands: [String]

    /// `usage`: the key's USB HID usage (`UIKey.keyCode.rawValue`); `characters`: its
    /// characters without modifiers. Nil for a key the text path delivers itself
    /// (letters, digits, Return, Tab and Backspace without Command or Control).
    public init?(usage: Int, characters: String, modifiers: RemoteBrowserWire.Modifiers) {
        let named: [Int: String] = [0x29: "Escape", 0x4A: "Home", 0x4B: "PageUp", 0x4C: "Delete", 0x4D: "End",
                                    0x4E: "PageDown", 0x4F: "ArrowRight", 0x50: "ArrowLeft", 0x51: "ArrowDown",
                                    0x52: "ArrowUp", 0x28: "Enter", 0x2A: "Backspace", 0x2B: "Tab"]
        let shortcut = modifiers.contains(.command) || modifiers.contains(.control)
        if let name = named[usage] {
            if ["Enter", "Backspace", "Tab"].contains(name), !shortcut { return nil }
            code = name
            key = name
        } else if shortcut, (0x04...0x1D).contains(usage) {
            let letter = Character(UnicodeScalar(UInt8(0x41 + usage - 0x04)))
            code = "Key\(letter)"
            key = characters.isEmpty ? String(letter).lowercased() : characters.lowercased()
        } else if shortcut, (0x1E...0x27).contains(usage) {
            let digit = usage == 0x27 ? 0 : usage - 0x1D
            code = "Digit\(digit)"
            key = String(digit)
        } else {
            return nil
        }
        self.modifiers = modifiers
        editCommands = Self.commands(code: code, modifiers: modifiers)
    }

    /// The Mac's key bindings for the key (Chromium's editor command names).
    static func commands(code: String, modifiers m: RemoteBrowserWire.Modifiers) -> [String] {
        let select = m.contains(.shift) ? "AndModifySelection" : ""
        if m.contains(.command) {
            switch code {
            case "KeyA": return ["SelectAll"]
            case "KeyC": return ["Copy"]
            case "KeyX": return ["Cut"]
            case "KeyZ": return [m.contains(.shift) ? "Redo" : "Undo"]
            case "ArrowLeft": return ["MoveToBeginningOfLine" + select]
            case "ArrowRight": return ["MoveToEndOfLine" + select]
            case "ArrowUp": return ["MoveToBeginningOfDocument" + select]
            case "ArrowDown": return ["MoveToEndOfDocument" + select]
            case "Backspace": return ["DeleteToBeginningOfLine"]
            default: return []
            }
        }
        if m.contains(.option) {
            switch code {
            case "ArrowLeft": return ["MoveWordLeft" + select]
            case "ArrowRight": return ["MoveWordRight" + select]
            case "Backspace": return ["DeleteWordBackward"]
            default: return []
            }
        }
        return []
    }

    /// The key down (with its edit commands) and up.
    public func events(_ wire: RemoteBrowserWire) -> [Data] {
        [wire.key(code, key: key, down: true, modifiers: modifiers, editCommands: editCommands),
         wire.key(code, key: key, down: false, modifiers: modifiers)]
    }
}
