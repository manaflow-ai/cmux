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
                guard !action.isSystemWideHotkey else { return nil }
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
#if DEBUG
    /// Process environment is fixed at launch; snapshot this DEBUG-only trace
    /// opt-in instead of rebuilding the environment on every keystroke.
    static let shortcutMonitorTraceEnvironmentEnabled =
        ProcessInfo.processInfo.environment["CMUX_SHORTCUT_MONITOR_TRACE"] == "1"
#endif

    /// Returns the already-resolved tab manager when plain terminal text can
    /// bypass browser, palette, and workspace shortcut-context resolution.
    func terminalTextShortcutBypassTabManagerBeforeContextResolution(
        event: NSEvent,
        normalizedFlags: NSEvent.ModifierFlags
    ) -> TabManager? {
        guard normalizedFlags.isEmpty,
              activeConfiguredShortcutChordPrefixForCurrentEvent == nil,
              event.cmuxIsPrintableTextInput,
              let window = event.window ?? shortcutRoutingKeyWindow,
              window.firstResponder is GhosttyNSView,
              NSApp.modalWindow == nil,
              window.attachedSheet == nil,
              let windowId = mainWindowId(from: window),
              let tabManager = tabManagerFor(windowId: windowId),
              !commandPaletteWindowStore.isVisible(windowId),
              !commandPaletteWindowStore.isPendingOpenRaw(windowId),
              !NotificationsPopoverVisibilityState.shared.isShown(in: window.windowNumber) else {
            return nil
        }

        guard shouldBypassPlainKeyShortcutRouting(
            event: event,
            normalizedFlags: normalizedFlags
        ) else {
            return nil
        }
        return tabManager
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

    func matchGlobalSearchShortcut(
        event: NSEvent,
        normalizedFlags: NSEvent.ModifierFlags? = nil
    ) -> Bool {
        guard !shouldBypassPrefixChordPassThrough(event) else { return false }
        let shortcut = globalSearchShortcutForRouting()
        guard let stroke = activeGlobalSearchStroke(for: shortcut),
              stroke.modifierFlags
                  == (normalizedFlags ?? ShortcutStroke.normalizedModifierFlags(from: event.modifierFlags)),
              matchShortcutStroke(event: event, stroke: stroke) else {
            return false
        }
        return globalSearchShortcutWhenClauseAllows(event: event)
    }

    /// Returns the foreground Search binding from the observer's authoritative snapshot.
    func globalSearchShortcutForRouting() -> StoredShortcut {
        KeyboardShortcutSettingsObserver.shared.globalSearchShortcut
    }

    private func activeGlobalSearchStroke(for shortcut: StoredShortcut) -> ShortcutStroke? {
        guard !shortcut.isUnbound else { return nil }
        if let activePrefix = activeConfiguredShortcutChordPrefixForCurrentEvent {
            guard shortcut.firstStroke.isRoutingEquivalent(to: activePrefix) else { return nil }
            return shortcut.secondStroke
        }
        return shortcut.hasChord ? nil : shortcut.firstStroke
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
