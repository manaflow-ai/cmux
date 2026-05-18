import AppKit
import Foundation

@MainActor
enum CmuxSystemShortcutMatcher {
    private static let appleSymbolicHotKeysDomain = "com.apple.symbolichotkeys"
    private static let appleSymbolicHotKeysKey = "AppleSymbolicHotKeys"
    // System Settings writes this domain from another process, so local UserDefaults notifications are not reliable.
    private static let defaultAppleSymbolicHotKeysCacheLifetime: TimeInterval = 2
    private static var cachedAppleSymbolicHotKeys: [String: Any]?
    private static var cachedAppleSymbolicHotKeysLoadedAt: TimeInterval?

#if DEBUG
    static var debugAppleSymbolicHotKeysProvider: (() -> [String: Any]?)? {
        didSet {
            invalidateAppleSymbolicHotKeysCache()
        }
    }

    static var debugAppleSymbolicHotKeysCacheLifetime: TimeInterval?
#endif

    static func shouldYieldTerminalCommandEquivalentToSystem(event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let normalizedFlags = ShortcutStroke.normalizedModifierFlags(from: event.modifierFlags)
        guard normalizedFlags.contains(.command) else { return false }
        return matchesEnabledAppleSymbolicHotKey(
            event: event,
            symbolicHotKeys: appleSymbolicHotKeys()
        )
    }

    private static func matchesEnabledAppleSymbolicHotKey(
        event: NSEvent,
        symbolicHotKeys: [String: Any]?
    ) -> Bool {
        guard let symbolicHotKeys else { return false }
        let eventFlags = ShortcutStroke.normalizedModifierFlags(from: event.modifierFlags)

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

            guard modifierRaw >= 0 else { continue }
            let shortcutFlags = ShortcutStroke.normalizedModifierFlags(
                from: NSEvent.ModifierFlags(rawValue: UInt(modifierRaw))
            )
            if Int(event.keyCode) == keyCode, eventFlags == shortcutFlags {
                return true
            }
        }

        return false
    }

    private static func appleSymbolicHotKeys() -> [String: Any]? {
        let now = ProcessInfo.processInfo.systemUptime
        if let cachedAppleSymbolicHotKeysLoadedAt,
           now - cachedAppleSymbolicHotKeysLoadedAt < appleSymbolicHotKeysCacheLifetime {
            return cachedAppleSymbolicHotKeys
        }

#if DEBUG
        if let debugAppleSymbolicHotKeysProvider {
            cachedAppleSymbolicHotKeys = debugAppleSymbolicHotKeysProvider()
        } else {
            cachedAppleSymbolicHotKeys = copyAppleSymbolicHotKeys()
        }
#else
        cachedAppleSymbolicHotKeys = copyAppleSymbolicHotKeys()
#endif
        cachedAppleSymbolicHotKeysLoadedAt = now
        return cachedAppleSymbolicHotKeys
    }

    private static func copyAppleSymbolicHotKeys() -> [String: Any]? {
        _ = CFPreferencesAppSynchronize(appleSymbolicHotKeysDomain as CFString)
        return CFPreferencesCopyAppValue(
            appleSymbolicHotKeysKey as CFString,
            appleSymbolicHotKeysDomain as CFString
        ) as? [String: Any]
    }

    private static var appleSymbolicHotKeysCacheLifetime: TimeInterval {
#if DEBUG
        if let debugAppleSymbolicHotKeysCacheLifetime {
            return debugAppleSymbolicHotKeysCacheLifetime
        }
#endif
        return defaultAppleSymbolicHotKeysCacheLifetime
    }

    private static func invalidateAppleSymbolicHotKeysCache() {
        cachedAppleSymbolicHotKeys = nil
        cachedAppleSymbolicHotKeysLoadedAt = nil
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
