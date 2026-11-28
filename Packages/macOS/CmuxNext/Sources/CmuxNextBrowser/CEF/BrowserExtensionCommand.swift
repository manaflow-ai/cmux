public import AppKit

/// One active extension keyboard shortcut (`chrome.commands`), as
/// `cmux_ext_commands` (fork API v3) reports it. The app routes these keys
/// itself: its window holds key focus, not the page's Views focus manager.
public nonisolated struct BrowserExtensionCommand: Hashable, Sendable {
    public var extensionID: String
    public var name: String
    public var summary: String
    /// Chromium `ui::KeyboardCode` (Windows virtual-key code).
    public var keyCode: Int
    /// Chromium `ui::EF_*` flags.
    public var modifiers: Int
    /// Display text, for example "⌘⇧Y".
    public var shortcut: String
    public var isGlobal: Bool

    public init(extensionID: String, name: String, summary: String = "", keyCode: Int, modifiers: Int,
                shortcut: String = "", isGlobal: Bool = false) {
        self.extensionID = extensionID
        self.name = name
        self.summary = summary
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.shortcut = shortcut
        self.isGlobal = isGlobal
    }

    /// `_execute_action` (and the MV2 browser/page action variants) click the
    /// toolbar action instead of dispatching `commands.onCommand`.
    public var isExecuteAction: Bool { name.hasPrefix("_execute_") }

    // ui::EF_* (ui/events/event_constants.h).
    static let shift = 1 << 1
    static let control = 1 << 2
    static let alt = 1 << 3
    static let command = 1 << 4

    public var modifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & Self.shift != 0 { flags.insert(.shift) }
        if modifiers & Self.control != 0 { flags.insert(.control) }
        if modifiers & Self.alt != 0 { flags.insert(.option) }
        if modifiers & Self.command != 0 { flags.insert(.command) }
        return flags
    }

    /// The key as `charactersIgnoringModifiers` reports it (lowercased), or
    /// nil for a key this mapping does not know.
    public var key: String? { Self.character(forVirtualKey: keyCode) }

    /// True when `event` (a key down) is this shortcut.
    public func matches(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, let key else { return false }
        let relevant: NSEvent.ModifierFlags = [.shift, .control, .option, .command]
        guard event.modifierFlags.intersection(relevant) == modifierFlags else { return false }
        return Self.eventKey(event) == key
    }

    static func eventKey(_ event: NSEvent) -> String? {
        switch Int(event.keyCode) {
        case 123: return "left"
        case 124: return "right"
        case 125: return "down"
        case 126: return "up"
        case 49: return " "
        default: break
        }
        if let function = functionKey(Int(event.keyCode)) { return function }
        return event.charactersIgnoringModifiers?.lowercased()
    }

    private static func functionKey(_ macKeyCode: Int) -> String? {
        let map: [Int: String] = [122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7",
                                  100: "f8", 101: "f9", 109: "f10", 103: "f11", 111: "f12"]
        return map[macKeyCode]
    }

    static func character(forVirtualKey code: Int) -> String? {
        switch code {
        case 0x30...0x39, 0x41...0x5A: return String(UnicodeScalar(UInt8(code))).lowercased()
        case 0x70...0x7B: return "f\(code - 0x6F)"
        case 0x25: return "left"
        case 0x26: return "up"
        case 0x27: return "right"
        case 0x28: return "down"
        case 0x20: return " "
        case 0xBC: return ","
        case 0xBE: return "."
        case 0xBA: return ";"
        case 0xBF: return "/"
        case 0xDB: return "["
        case 0xDD: return "]"
        case 0xBD: return "-"
        case 0xBB: return "="
        default: return nil
        }
    }

    /// Decodes the fork's JSON array. Invalid input yields an empty list.
    public static func decodeList(_ json: String) -> [BrowserExtensionCommand] {
        guard let data = json.data(using: .utf8),
              let items = try? JSONDecoder().decode([Wire].self, from: data) else {
            return []
        }
        return items.map {
            BrowserExtensionCommand(extensionID: $0.extension_id, name: $0.name, summary: $0.description ?? "",
                                    keyCode: $0.key_code, modifiers: $0.modifiers, shortcut: $0.shortcut ?? "",
                                    isGlobal: $0.global ?? false)
        }
    }

    private struct Wire: Decodable {
        var extension_id: String
        var name: String
        var description: String?
        var key_code: Int
        var modifiers: Int
        var shortcut: String?
        var global: Bool?
    }
}
