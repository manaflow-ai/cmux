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
                guard !action.isBrowserContentShortcut else { return nil }
                guard action.participatesInAppWideBareStartRouting else { return nil }
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

private extension KeyboardShortcutSettings.Action {
    var participatesInAppWideBareStartRouting: Bool {
        switch self {
        case .fileExplorerOpenSelection, .fileExplorerOpenSelectionFinderAlias:
            return false
        default:
            return true
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
    /// Plain terminal text cannot trigger an app-wide shortcut unless it is an
    /// explicitly configured bare start (currently Space and named special
    /// keys). Reject that common case before resolving browser, palette, or
    /// workspace focus context.
    func shouldBypassTerminalTextShortcutRoutingBeforeContextResolution(
        event: NSEvent,
        normalizedFlags: NSEvent.ModifierFlags
    ) -> Bool {
        guard normalizedFlags.isEmpty,
              activeConfiguredShortcutChordPrefixForCurrentEvent == nil,
              event.cmuxIsPrintableTextInput,
              let window = event.window,
              window.firstResponder is GhosttyNSView,
              NSApp.modalWindow == nil,
              window.attachedSheet == nil,
              let windowId = mainWindowId(from: window),
              !commandPaletteWindowStore.isVisible(windowId),
              !commandPaletteWindowStore.isPendingOpenRaw(windowId),
              !NotificationsPopoverVisibilityState.shared.isShown(in: window.windowNumber) else {
            return false
        }

        return shouldBypassPlainKeyShortcutRouting(
            event: event,
            normalizedFlags: normalizedFlags
        )
    }

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

private extension NSEvent {
    var cmuxIsPrintableTextInput: Bool {
        guard let characters, !characters.isEmpty else { return false }
        return characters.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
                && (scalar.value < 0xF700 || scalar.value > 0xF8FF)
        }
    }
}
