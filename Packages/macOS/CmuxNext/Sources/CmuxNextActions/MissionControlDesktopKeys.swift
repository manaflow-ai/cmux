import Foundation

/// macOS Mission Control's "Switch to Desktop 1…9" shortcuts as the user's
/// `com.apple.symbolichotkeys` preferences have them. They are off by
/// default; when one is on with the same modifiers as cmux's tabs-by-number
/// family (Ctrl-1…9), macOS takes the key first and the tab never switches.
///
/// ```swift
/// let desktops = MissionControlDesktopKeys(symbolicHotKeys: hotKeys)
/// desktops.conflicts(withDigitModifiers: NSEvent.ModifierFlags.control.rawValue)
/// ```
public nonisolated struct MissionControlDesktopKeys: Sendable, Equatable {
    /// The `AppleSymbolicHotKeys` ids of Switch to Desktop 1…9.
    public static let desktopHotKeyIDs = 118...126
    /// The preferences domain and key that hold them.
    public static let preferencesDomain = "com.apple.symbolichotkeys"
    public static let preferencesKey = "AppleSymbolicHotKeys"

    /// The modifiers (`NSEvent.ModifierFlags` raw values, device independent)
    /// of each Switch to Desktop shortcut that is on.
    public let enabledModifiers: Set<UInt>

    /// Parses the `AppleSymbolicHotKeys` dictionary: id string to
    /// `{enabled, value: {parameters: [char, keyCode, modifiers]}}`.
    /// - Parameter symbolicHotKeys: The dictionary, or nil when the user never changed one (all off).
    public init(symbolicHotKeys: [String: Any]?) {
        var modifiers = Set<UInt>()
        for id in Self.desktopHotKeyIDs {
            guard let entry = symbolicHotKeys?[String(id)] as? [String: Any], Self.isOn(entry["enabled"]) else { continue }
            let parameters = (entry["value"] as? [String: Any])?["parameters"] as? [Any]
            // An entry on without parameters uses the system default, Ctrl plus the digit.
            let raw = (parameters?.count ?? 0) >= 3 ? Self.number(parameters?[2]) : Self.controlMask
            modifiers.insert(raw & Self.modifierMask)
        }
        enabledModifiers = modifiers
    }

    /// Whether a Switch to Desktop shortcut that is on uses exactly `modifiers` plus a digit.
    public func conflicts(withDigitModifiers modifiers: UInt) -> Bool {
        enabledModifiers.contains(modifiers & Self.modifierMask)
    }

    /// Shift, Control, Option, Command (the same bits in the hot key
    /// parameters and `NSEvent.ModifierFlags`).
    static let modifierMask: UInt = 0x1E_0000
    static let controlMask: UInt = 0x4_0000

    private static func isOn(_ value: Any?) -> Bool {
        if let flag = value as? Bool { return flag }
        return number(value) != 0
    }

    private static func number(_ value: Any?) -> UInt {
        if let number = value as? NSNumber { return number.uintValue }
        if let int = value as? Int, int >= 0 { return UInt(int) }
        return 0
    }
}
