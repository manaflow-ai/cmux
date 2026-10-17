public import AppKit

/// The macOS "Show Help menu" shortcut from System Settings.
///
/// AppKit opens the Help menu with its search field focused when this chord
/// reaches it unhandled. The default is Command-Shift-/ (keyCode 44).
public struct SystemHelpMenuShortcut: Equatable, Sendable {
    public let keyCode: UInt16
    public let modifierFlags: NSEvent.ModifierFlags

    /// AppKit's default binding, used when System Settings has no override.
    public static let appKitDefault = SystemHelpMenuShortcut(keyCode: 44, modifierFlags: [.command, .shift])

    /// The symbolic hot key ID of "Show Help menu".
    static let symbolicHotKeyID = "98"

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
    public static func resolve(symbolicHotKeys: [String: Any]?) -> SystemHelpMenuShortcut? {
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
        return SystemHelpMenuShortcut(
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
    public static func current() -> SystemHelpMenuShortcut? {
        resolve(symbolicHotKeys: symbolicHotKeysDefaults?.dictionary(forKey: "AppleSymbolicHotKeys"))
    }

    /// Whether the event is exactly this shortcut.
    public func matches(keyCode eventKeyCode: UInt16, modifierFlags eventFlags: NSEvent.ModifierFlags) -> Bool {
        eventKeyCode == keyCode && Self.normalized(eventFlags) == modifierFlags
    }

    /// Drops flags that describe the key rather than the chord, so a binding
    /// stored with the fn bit (an F-key remap) still matches its key press.
    private static func normalized(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
    }
}
