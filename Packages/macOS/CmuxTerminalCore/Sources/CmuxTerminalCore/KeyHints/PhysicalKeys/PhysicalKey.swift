import Foundation

/// A key on a keyboard, identified by its HID usage page and usage.
///
/// Keyboard keys are on page 7 (`0x07`); Apple's fn key is page `0xFF`,
/// usage 3. Karabiner-Elements names the same keys by `key_code`
/// (`left_control`, `caps_lock`, `o`), and System Settings and `hidutil`
/// store them as `page << 32 | usage`. A key that isn't in the name table
/// keeps its raw usage and displays as its hex usage.
public struct PhysicalKey: Hashable, Sendable {
    /// The HID usage page.
    public var usagePage: UInt32
    /// The HID usage within the page.
    public var usage: UInt32

    /// - Parameters:
    ///   - usagePage: The HID usage page, `7` for keyboard keys.
    ///   - usage: The HID usage within the page.
    public init(usagePage: UInt32, usage: UInt32) {
        self.usagePage = usagePage
        self.usage = usage
    }

    /// A key from its combined `page << 32 | usage` form, as System Settings
    /// and `hidutil` store it. Apple's two fn usages read as ``fn``.
    ///
    /// - Parameter hidUsage: The combined page and usage.
    public init(hidUsage: UInt64) {
        let page = UInt32(truncatingIfNeeded: hidUsage >> 32)
        let usage = UInt32(truncatingIfNeeded: hidUsage)
        if (page == 0xFF || page == 0xFF01), usage == 3 {
            self = .fn
        } else {
            self.init(usagePage: page, usage: usage)
        }
    }

    /// The key Karabiner-Elements names `keyCode`, or `nil` for a name
    /// outside the table.
    ///
    /// - Parameter keyCode: A Karabiner `key_code`, such as `left_control`.
    public init?(karabinerKeyCode keyCode: String) {
        guard let entry = Self.entriesByName[keyCode] else { return nil }
        self = entry.key
    }

    /// Karabiner-Elements' `key_code` for this key, when it has one.
    public var karabinerKeyCode: String? {
        Self.entriesByKey[self]?.name
    }

    /// The modifier this key is, if it is a Control, Option, Shift, or
    /// Command key.
    public var modifier: KeyboardModifier? {
        guard usagePage == 7 else { return nil }
        switch usage {
        case 0xE0, 0xE4: return .control
        case 0xE1, 0xE5: return .shift
        case 0xE2, 0xE6: return .option
        case 0xE3, 0xE7: return .command
        default: return nil
        }
    }

    /// Whether this is a right-hand modifier key.
    public var isRightModifier: Bool {
        usagePage == 7 && (0xE4...0xE7).contains(usage)
    }

    /// Whether the key can be held while another key is pressed: a modifier,
    /// Caps Lock, or fn.
    public var isHoldable: Bool {
        modifier != nil || self == .capsLock || self == .fn
    }

    /// What the key's cap shows: `⌃`, `⇪`, `⎋`, `O`, `F13`.
    public var glyph: String {
        if let modifier { return modifier.glyph }
        if let glyph = Self.entriesByKey[self]?.glyph { return glyph }
        return String(format: "0x%02X:%02X", usagePage, usage)
    }

    /// The key's name for a sentence, for the keys whose glyph alone is
    /// unclear; `nil` for keys that read fine as their glyph.
    public var name: PhysicalKeyName? {
        if let modifier {
            switch modifier {
            case .control: return .control
            case .shift: return .shift
            case .option: return .option
            case .command: return .command
            }
        }
        switch self {
        case .capsLock: return .capsLock
        case .escape: return .escape
        default: return nil
        }
    }

    /// The HID "no event" usage that System Settings and `hidutil` map a
    /// key to when it should do nothing.
    public static let noAction = PhysicalKey(usagePage: 7, usage: 0)
    public static let leftControl = PhysicalKey(usagePage: 7, usage: 0xE0)
    public static let leftShift = PhysicalKey(usagePage: 7, usage: 0xE1)
    public static let leftOption = PhysicalKey(usagePage: 7, usage: 0xE2)
    public static let leftCommand = PhysicalKey(usagePage: 7, usage: 0xE3)
    public static let rightControl = PhysicalKey(usagePage: 7, usage: 0xE4)
    public static let rightShift = PhysicalKey(usagePage: 7, usage: 0xE5)
    public static let rightOption = PhysicalKey(usagePage: 7, usage: 0xE6)
    public static let rightCommand = PhysicalKey(usagePage: 7, usage: 0xE7)
    public static let capsLock = PhysicalKey(usagePage: 7, usage: 0x39)
    public static let escape = PhysicalKey(usagePage: 7, usage: 0x29)
    public static let fn = PhysicalKey(usagePage: 0xFF, usage: 3)

    /// Every key in the name table, for searching which physical keys
    /// produce a wanted key.
    static let allNamed: [PhysicalKey] = entries.map(\.key)

    private struct Entry {
        var name: String
        var key: PhysicalKey
        var glyph: String
    }

    private static let entries: [Entry] = {
        var entries: [Entry] = []
        func add(_ name: String, _ usage: UInt32, _ glyph: String) {
            entries.append(Entry(name: name, key: PhysicalKey(usagePage: 7, usage: usage), glyph: glyph))
        }
        for (offset, letter) in "abcdefghijklmnopqrstuvwxyz".enumerated() {
            add(String(letter), 0x04 + UInt32(offset), String(letter).uppercased())
        }
        for (offset, digit) in "1234567890".enumerated() {
            add(String(digit), 0x1E + UInt32(offset), String(digit))
        }
        add("return_or_enter", 0x28, "↩")
        add("escape", 0x29, "⎋")
        add("delete_or_backspace", 0x2A, "⌫")
        add("tab", 0x2B, "⇥")
        add("spacebar", 0x2C, "Space")
        add("hyphen", 0x2D, "-")
        add("equal_sign", 0x2E, "=")
        add("open_bracket", 0x2F, "[")
        add("close_bracket", 0x30, "]")
        add("backslash", 0x31, "\\")
        add("non_us_pound", 0x32, "#")
        add("semicolon", 0x33, ";")
        add("quote", 0x34, "'")
        add("grave_accent_and_tilde", 0x35, "`")
        add("comma", 0x36, ",")
        add("period", 0x37, ".")
        add("slash", 0x38, "/")
        add("caps_lock", 0x39, "⇪")
        for number in 1...12 {
            add("f\(number)", 0x3A + UInt32(number - 1), "F\(number)")
        }
        add("print_screen", 0x46, "PrtSc")
        add("scroll_lock", 0x47, "ScrLk")
        add("pause", 0x48, "Pause")
        add("insert", 0x49, "Ins")
        add("home", 0x4A, "↖")
        add("page_up", 0x4B, "⇞")
        add("delete_forward", 0x4C, "⌦")
        add("end", 0x4D, "↘")
        add("page_down", 0x4E, "⇟")
        add("right_arrow", 0x4F, "→")
        add("left_arrow", 0x50, "←")
        add("down_arrow", 0x51, "↓")
        add("up_arrow", 0x52, "↑")
        add("non_us_backslash", 0x64, "§")
        add("application", 0x65, "Menu")
        for number in 13...24 {
            add("f\(number)", 0x68 + UInt32(number - 13), "F\(number)")
        }
        add("left_control", 0xE0, "⌃")
        add("left_shift", 0xE1, "⇧")
        add("left_option", 0xE2, "⌥")
        add("left_command", 0xE3, "⌘")
        add("right_control", 0xE4, "⌃")
        add("right_shift", 0xE5, "⇧")
        add("right_option", 0xE6, "⌥")
        add("right_command", 0xE7, "⌘")
        entries.append(Entry(name: "fn", key: .fn, glyph: "fn"))
        return entries
    }()

    private static let entriesByName: [String: Entry] = Dictionary(
        entries.map { ($0.name, $0) },
        uniquingKeysWith: { first, _ in first }
    )
    private static let entriesByKey: [PhysicalKey: Entry] = Dictionary(
        entries.map { ($0.key, $0) },
        uniquingKeysWith: { first, _ in first }
    )
}
