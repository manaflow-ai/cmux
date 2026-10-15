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
              GlobalSearchCoordinator.shared.isPaletteVisible() else {
            return .notApplicable
        }
        guard !KeyboardShortcutRecorderActivity.isAnyRecorderActive,
              !RecorderHostButton.isActivelyRecording else {
            clearConfiguredShortcutChordState()
            return .notApplicable
        }

        let shortcuts = globalSearchShortcutsForRouting()
        guard !shortcuts.isEmpty else { return .notApplicable }

        let normalizedFlags = ShortcutStroke.normalizedModifierFlags(from: event.modifierFlags)
        let matchingBinding = shortcuts.first { binding in
            let shortcut = binding.shortcut
            let hasMatchingChordState =
                activeConfiguredShortcutChordPrefixForCurrentEvent == shortcut.firstStroke
                || pendingConfiguredShortcutChord?.firstStroke == shortcut.firstStroke
            let matchesFirstStroke =
                activeConfiguredShortcutChordPrefixForCurrentEvent == nil
                && shortcut.firstStroke.modifierFlags == normalizedFlags
                && matchShortcutStroke(event: event, stroke: shortcut.firstStroke)
            return hasMatchingChordState || matchesFirstStroke
        }
        guard let matchingBinding else {
            return .notApplicable
        }
        let shortcut = matchingBinding.shortcut

        let previousPendingChord = pendingConfiguredShortcutChord
        let previousActiveChord = activeConfiguredShortcutChordPrefixForCurrentEvent
        let eventWindowNumber = configuredShortcutChordWindowNumber(for: event)
        if let pendingConfiguredShortcutChord,
           pendingConfiguredShortcutChord.windowNumber == eventWindowNumber,
           pendingConfiguredShortcutChord.firstStroke == shortcut.firstStroke {
            activeConfiguredShortcutChordPrefixForCurrentEvent =
                pendingConfiguredShortcutChord.firstStroke
        } else if activeConfiguredShortcutChordPrefixForCurrentEvent
            != shortcut.firstStroke {
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
        let shortcuts = globalSearchShortcutsForRouting().map(\.shortcut)
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
               shortcuts: shortcuts
           ) {
            return .handled
        }
        return .notApplicable
    }

    func matchesUnarmedGlobalSearchChordPrefix(
        _ event: NSEvent,
        normalizedFlags: NSEvent.ModifierFlags
    ) -> Bool {
        activeConfiguredShortcutChordPrefixForCurrentEvent == nil
            && globalSearchShortcutsForRouting().contains { binding in
                binding.shortcut.hasChord
                    && binding.shortcut.firstStroke.modifierFlags == normalizedFlags
                    && matchShortcutStroke(event: event, stroke: binding.shortcut.firstStroke)
                    && binding.whenClause.evaluate(
                        shortcutWhenClauseContext(
                            for: .globalSearch,
                            clause: binding.whenClause,
                            event: event
                        )
                    )
            }
    }
}
