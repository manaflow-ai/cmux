public import AppKit

/// The macOS "Move focus to next window" shortcut from System Settings.
///
/// AppKit cycles an app's windows with this key and with the same key plus
/// Shift. The default is Command and the key left of 1 on US keyboards
/// (keyCode 50), but ISO keyboards and user remaps report other key codes, such
/// as the section key (keyCode 10).
public struct SystemWindowCyclingShortcut: Equatable, Sendable {
    public let keyCode: UInt16
    public let modifierFlags: NSEvent.ModifierFlags

    /// AppKit's default binding, used when System Settings has no override.
    public static let appKitDefault = SystemWindowCyclingShortcut(keyCode: 50, modifierFlags: [.command])

    /// The symbolic hot key ID of "Move focus to next window".
    static let symbolicHotKeyID = "27"

    /// Creates a binding for a key code and modifiers, dropping flags that
    /// describe the key rather than the chord.
    public init(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifierFlags = Self.normalized(modifierFlags)
    }

    /// Reads the binding from an `AppleSymbolicHotKeys` dictionary.
    ///
    /// Returns ``appKitDefault`` when the entry is missing, since the domain only
    /// stores entries the user or the system changed, and `nil` when the
    /// shortcut is disabled or malformed.
    public static func resolve(symbolicHotKeys: [String: Any]?) -> SystemWindowCyclingShortcut? {
        guard let entry = symbolicHotKeys?[symbolicHotKeyID] as? [String: Any] else {
            return appKitDefault
        }
        if let enabled = entry["enabled"] as? Bool, !enabled {
            return nil
        }
        guard let value = entry["value"] as? [String: Any],
              let parameters = value["parameters"] as? [Any],
              parameters.count >= 3,
              let keyCode = (parameters[1] as? NSNumber)?.intValue,
              let modifiers = (parameters[2] as? NSNumber)?.uintValue,
              let validKeyCode = UInt16(exactly: keyCode) else {
            return nil
        }
        return SystemWindowCyclingShortcut(
            keyCode: validKeyCode,
            modifierFlags: NSEvent.ModifierFlags(rawValue: modifiers)
        )
    }

    /// The system domain that stores keyboard shortcuts from System Settings.
    /// Reads go through cfprefsd, so edits in System Settings show up without
    /// restarting cmux.
    nonisolated(unsafe) private static let symbolicHotKeysDefaults = UserDefaults(
        suiteName: "com.apple.symbolichotkeys"
    )

    /// The binding currently configured in System Settings.
    public static func current() -> SystemWindowCyclingShortcut? {
        current(defaults: symbolicHotKeysDefaults)
    }

    /// The binding stored in `defaults`, resolved as ``resolve(symbolicHotKeys:)`` does.
    static func current(defaults: UserDefaults?) -> SystemWindowCyclingShortcut? {
        resolve(symbolicHotKeys: defaults?.dictionary(forKey: "AppleSymbolicHotKeys"))
    }

    /// Whether the event is this shortcut, forward or with Shift for backward.
    public func matches(keyCode eventKeyCode: UInt16, modifierFlags eventFlags: NSEvent.ModifierFlags) -> Bool {
        guard eventKeyCode == keyCode else { return false }
        let flags = Self.normalized(eventFlags)
        return flags == modifierFlags || flags == modifierFlags.union(.shift)
    }

    /// Drops flags that describe the key rather than the chord, so a binding
    /// stored with the fn bit (an F-key remap) still matches its key press.
    private static func normalized(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
    }
}
