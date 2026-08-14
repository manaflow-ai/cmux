import AppKit
import CmuxSettingsUI

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
              GlobalSearchCoordinator.shared.isPaletteVisible(),
              !shouldBypassPrefixChordPassThrough(event) else {
            return .notApplicable
        }
        guard !KeyboardShortcutRecorderActivity.isAnyRecorderActive,
              !RecorderHostButton.isActivelyRecording else {
            clearConfiguredShortcutChordState()
            return .notApplicable
        }

        let shortcut = globalSearchShortcutForRouting()
        guard !shortcut.isUnbound else { return .notApplicable }

        let normalizedFlags = ShortcutStroke.normalizedModifierFlags(from: event.modifierFlags)
        let hasMatchingChordState =
            activeConfiguredShortcutChordPrefixForCurrentEvent?.isRoutingEquivalent(to: shortcut.firstStroke) == true
            || pendingConfiguredShortcutChord?.firstStroke.isRoutingEquivalent(to: shortcut.firstStroke) == true
        let matchesFirstStroke =
            activeConfiguredShortcutChordPrefixForCurrentEvent == nil
            && shortcut.firstStroke.modifierFlags == normalizedFlags
            && matchShortcutStroke(event: event, stroke: shortcut.firstStroke)
        guard hasMatchingChordState || matchesFirstStroke else {
            return .notApplicable
        }

        let previousPendingChord = pendingConfiguredShortcutChord
        let previousActiveChord = activeConfiguredShortcutChordPrefixForCurrentEvent
        let eventWindowNumber = configuredShortcutChordWindowNumber(for: event)
        if let pendingConfiguredShortcutChord,
           pendingConfiguredShortcutChord.windowNumber == eventWindowNumber,
           pendingConfiguredShortcutChord.firstStroke.isRoutingEquivalent(to: shortcut.firstStroke) {
            activeConfiguredShortcutChordPrefixForCurrentEvent =
                pendingConfiguredShortcutChord.firstStroke
        } else if activeConfiguredShortcutChordPrefixForCurrentEvent?.isRoutingEquivalent(to: shortcut.firstStroke) != true {
            activeConfiguredShortcutChordPrefixForCurrentEvent = nil
        }
        pendingConfiguredShortcutChord = nil

        let route = routeVisibleGlobalSearchShortcut(
            event,
            normalizedFlags: normalizedFlags
        )
        if case .notApplicable = route {
            pendingConfiguredShortcutChord = previousPendingChord
            activeConfiguredShortcutChordPrefixForCurrentEvent = previousActiveChord
        } else {
            activeConfiguredShortcutChordPrefixForCurrentEvent = nil
        }
        return route
    }

    /// Applies the single visible-palette toggle policy for every local monitor.
    func routeVisibleGlobalSearchShortcut(
        _ event: NSEvent,
        normalizedFlags: NSEvent.ModifierFlags
    ) -> VisibleGlobalSearchShortcutRoute {
        guard !shouldBypassPrefixChordPassThrough(event) else {
            return .notApplicable
        }
        let shortcut = globalSearchShortcutForRouting()
        let matchesShortcut = matchGlobalSearchShortcut(
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
        guard GlobalSearchCoordinator.shared.isPaletteVisible() else {
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
        let shortcut = globalSearchShortcutForRouting()
        return shortcut.hasChord
            && activeConfiguredShortcutChordPrefixForCurrentEvent == nil
            && shortcut.firstStroke.modifierFlags == normalizedFlags
            && matchShortcutStroke(event: event, stroke: shortcut.firstStroke)
    }
}
