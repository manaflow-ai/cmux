import AppKit
import Foundation

enum KeyboardShortcutBareStartCache {
    private static var configuredKeys: Set<String>?
    private static var observer: NSObjectProtocol?

    static func hasConfiguredBareShortcutStart(key: String) -> Bool {
        installObserverIfNeeded()

        let normalizedKey = key.lowercased()
        if let configuredKeys {
            return configuredKeys.contains(normalizedKey)
        }

        let resolvedKeys = Set(
            KeyboardShortcutSettings.Action.allCases.compactMap { action -> String? in
                guard action != .showHideAllWindows else { return nil }
                return KeyboardShortcutSettings.shortcut(for: action).bareShortcutStartKey
            }
        )
        configuredKeys = resolvedKeys
        return resolvedKeys.contains(normalizedKey)
    }

    private static func installObserverIfNeeded() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: KeyboardShortcutSettings.didChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            configuredKeys = nil
        }
    }
}

extension StoredShortcut {
    var bareShortcutStartKey: String? {
        guard !isUnbound, firstStroke.modifierFlags.isEmpty else { return nil }
        return key.lowercased()
    }
}

func bareShortcutFastPathKey(for event: NSEvent) -> String? {
    if event.keyCode == 49 {
        return "space"
    }

    guard event.specialKey != nil,
          let stroke = ShortcutStroke.from(event: event, requireModifier: false),
          stroke.modifierFlags.isEmpty else {
        return nil
    }
    return stroke.key.lowercased()
}

extension AppDelegate {
    func shouldBypassPlainKeyShortcutRouting(
        event: NSEvent,
        normalizedFlags: NSEvent.ModifierFlags
    ) -> Bool {
        guard normalizedFlags.isEmpty,
              activeConfiguredShortcutChordPrefixForCurrentEvent == nil else {
            return false
        }

        guard let bareShortcutKey = bareShortcutFastPathKey(for: event) else {
            return true
        }

        guard !KeyboardShortcutBareStartCache.hasConfiguredBareShortcutStart(key: bareShortcutKey) else {
            return false
        }

        let configuredCmuxShortcutContext = preferredMainWindowContextForShortcutRouting(event: event)
        return !configuredCmuxShortcutActions(for: configuredCmuxShortcutContext).contains {
            $0.shortcut?.bareShortcutStartKey == bareShortcutKey
        }
    }
}
