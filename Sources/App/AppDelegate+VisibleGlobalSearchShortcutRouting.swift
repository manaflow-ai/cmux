import AppKit

extension AppDelegate {
    enum VisibleGlobalSearchShortcutRoute {
        case notApplicable
        case handled
        case queryOwnsEvent
    }

    /// Routes the visible Search palette's configured toggle before its local
    /// monitor applies generic query-key handling.
    func routeVisibleGlobalSearchShortcutFromLocalMonitor(
        _ event: NSEvent
    ) -> VisibleGlobalSearchShortcutRoute {
        guard event.type == .keyDown,
              GlobalSearchCoordinator.shared.isPaletteVisible() else {
            return .notApplicable
        }
        guard !KeyboardShortcutRecorderActivity.isAnyRecorderActive,
              !RecorderHostButton.isActivelyRecording else {
            clearConfiguredShortcutChordState()
            return .notApplicable
        }

        let shortcut = KeyboardShortcutSettingsObserver.shared.globalSearchShortcut
        guard !shortcut.isUnbound else { return .notApplicable }

        let normalizedFlags = ShortcutStroke.normalizedModifierFlags(from: event.modifierFlags)
        let hasMatchingChordState =
            activeConfiguredShortcutChordPrefixForCurrentEvent == shortcut.firstStroke
            || pendingConfiguredShortcutChord?.firstStroke == shortcut.firstStroke
        let matchesFirstStroke =
            activeConfiguredShortcutChordPrefixForCurrentEvent == nil
            && shortcut.firstStroke.modifierFlags == normalizedFlags
            && matchShortcutStroke(event: event, stroke: shortcut.firstStroke)
        guard hasMatchingChordState || matchesFirstStroke else {
            return .notApplicable
        }

        let eventWindowNumber = configuredShortcutChordWindowNumber(for: event)
        if let pendingConfiguredShortcutChord,
           pendingConfiguredShortcutChord.windowNumber == eventWindowNumber {
            activeConfiguredShortcutChordPrefixForCurrentEvent =
                pendingConfiguredShortcutChord.firstStroke
        } else {
            activeConfiguredShortcutChordPrefixForCurrentEvent = nil
        }
        pendingConfiguredShortcutChord = nil
        defer { activeConfiguredShortcutChordPrefixForCurrentEvent = nil }

        return routeVisibleGlobalSearchShortcut(
            event,
            normalizedFlags: normalizedFlags
        )
    }

    /// Applies the single visible-palette toggle policy for every local monitor.
    func routeVisibleGlobalSearchShortcut(
        _ event: NSEvent,
        normalizedFlags: NSEvent.ModifierFlags
    ) -> VisibleGlobalSearchShortcutRoute {
        guard GlobalSearchCoordinator.shared.isPaletteVisible() else {
            return .notApplicable
        }

        let shortcut = KeyboardShortcutSettingsObserver.shared.globalSearchShortcut
        let matchesShortcut = matchCachedGlobalSearchShortcut(
            event: event,
            normalizedFlags: normalizedFlags
        )
        let matchesUnarmedChordPrefix = matchesUnarmedGlobalSearchChordPrefix(
            event,
            normalizedFlags: normalizedFlags
        )
        guard matchesShortcut || matchesUnarmedChordPrefix else {
            return .notApplicable
        }

        if activeConfiguredShortcutChordPrefixForCurrentEvent == nil,
           GlobalSearchKeyEvent(event).queryOwnsEditingShortcut {
            return .queryOwnsEvent
        }
        if matchesShortcut {
            toggleGlobalSearchPalette()
            return .handled
        }
        if globalSearchShortcutWhenClauseAllows(event: event),
           armConfiguredShortcutChordIfNeeded(
               event: event,
               actions: [],
               shortcuts: [shortcut]
           ) {
            return .handled
        }
        return .notApplicable
    }

    func matchesUnarmedGlobalSearchChordPrefix(
        _ event: NSEvent,
        normalizedFlags: NSEvent.ModifierFlags
    ) -> Bool {
        let shortcut = KeyboardShortcutSettingsObserver.shared.globalSearchShortcut
        return shortcut.hasChord
            && activeConfiguredShortcutChordPrefixForCurrentEvent == nil
            && shortcut.firstStroke.modifierFlags == normalizedFlags
            && matchShortcutStroke(event: event, stroke: shortcut.firstStroke)
    }
}
