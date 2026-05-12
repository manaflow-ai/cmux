import AppKit
import Foundation

enum CmuxSystemShortcutMatcher {
    private static let appleSymbolicHotKeysDomain = "com.apple.symbolichotkeys"
    private static let appleSymbolicHotKeysKey = "AppleSymbolicHotKeys"

#if DEBUG
    static var debugAppleSymbolicHotKeysProvider: (() -> [String: Any]?)?
#endif

    static func shouldYieldTerminalCommandEquivalentToSystem(event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let normalizedFlags = normalizedModifierFlags(event.modifierFlags)
        guard normalizedFlags.contains(.command) else { return false }
        return matchesEnabledAppleSymbolicHotKey(
            event: event,
            symbolicHotKeys: appleSymbolicHotKeys()
        )
    }

    static func matchesEnabledAppleSymbolicHotKey(
        event: NSEvent,
        symbolicHotKeys: [String: Any]?
    ) -> Bool {
        guard let symbolicHotKeys else { return false }
        let eventFlags = normalizedModifierFlags(event.modifierFlags)

        for rawEntry in symbolicHotKeys.values {
            guard let entry = rawEntry as? [String: Any],
                  boolValue(entry["enabled"]),
                  let value = entry["value"] as? [String: Any],
                  let parameters = value["parameters"] as? [Any],
                  parameters.count >= 3,
                  let keyCode = intValue(parameters[1]),
                  let modifierRaw = intValue(parameters[2]) else {
                continue
            }

            let shortcutFlags = normalizedModifierFlags(
                NSEvent.ModifierFlags(rawValue: UInt(modifierRaw))
            )
            if Int(event.keyCode) == keyCode, eventFlags == shortcutFlags {
                return true
            }
        }

        return false
    }

    private static func appleSymbolicHotKeys() -> [String: Any]? {
#if DEBUG
        if let debugAppleSymbolicHotKeysProvider {
            return debugAppleSymbolicHotKeysProvider()
        }
#endif
        return CFPreferencesCopyAppValue(
            appleSymbolicHotKeysKey as CFString,
            appleSymbolicHotKeysDomain as CFString
        ) as? [String: Any]
    }

    private static func normalizedModifierFlags(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
    }

    private static func boolValue(_ value: Any?) -> Bool {
        if let value = value as? Bool {
            return value
        }
        if let value = value as? NSNumber {
            return value.boolValue
        }
        return false
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }
        if let value = value as? NSNumber {
            return value.intValue
        }
        return nil
    }
}
