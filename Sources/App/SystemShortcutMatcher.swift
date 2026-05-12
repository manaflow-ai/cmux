import AppKit
import Foundation

@MainActor
enum CmuxSystemShortcutMatcher {
    private static let appleSymbolicHotKeysDomain = "com.apple.symbolichotkeys"
    private static let appleSymbolicHotKeysKey = "AppleSymbolicHotKeys"
    private static var cachedAppleSymbolicHotKeys: [String: Any]?
    private static var hasLoadedAppleSymbolicHotKeys = false
    private static var appleSymbolicHotKeysObserver: NSObjectProtocol?

#if DEBUG
    static var debugAppleSymbolicHotKeysProvider: (() -> [String: Any]?)? {
        didSet {
            invalidateAppleSymbolicHotKeysCache()
        }
    }
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

    private static func matchesEnabledAppleSymbolicHotKey(
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
        installAppleSymbolicHotKeysInvalidationObserverIfNeeded()
        guard !hasLoadedAppleSymbolicHotKeys else {
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
        hasLoadedAppleSymbolicHotKeys = true
        return cachedAppleSymbolicHotKeys
    }

    private static func copyAppleSymbolicHotKeys() -> [String: Any]? {
        return CFPreferencesCopyAppValue(
            appleSymbolicHotKeysKey as CFString,
            appleSymbolicHotKeysDomain as CFString
        ) as? [String: Any]
    }

    private static func installAppleSymbolicHotKeysInvalidationObserverIfNeeded() {
        guard appleSymbolicHotKeysObserver == nil else { return }
        appleSymbolicHotKeysObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: nil
        ) { _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    invalidateAppleSymbolicHotKeysCache()
                }
            } else {
                Task { @MainActor in
                    invalidateAppleSymbolicHotKeysCache()
                }
            }
        }
    }

    private static func invalidateAppleSymbolicHotKeysCache() {
        cachedAppleSymbolicHotKeys = nil
        hasLoadedAppleSymbolicHotKeys = false
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
