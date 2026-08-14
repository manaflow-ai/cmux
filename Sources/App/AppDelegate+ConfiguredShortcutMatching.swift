import AppKit

extension AppDelegate {
    func resolvedShortcutEventWindow(_ event: NSEvent) -> NSWindow? {
        if let window = event.window {
            return window
        }
        let eventWindowNumber = event.windowNumber
        guard eventWindowNumber > 0 else { return nil }
#if DEBUG
        if let window = debugShortcutRoutingFocusedWindowOverrideForTesting.window,
           window.windowNumber == eventWindowNumber {
            return window
        }
#endif
        return NSApp.window(withWindowNumber: eventWindowNumber)
    }

    private func matchConfiguredShortcut(
        event: NSEvent,
        shortcut: StoredShortcut
    ) -> Bool {
        guard !shouldBypassPrefixChordPassThrough(event),
              !shortcut.isUnbound else {
            return false
        }
        if let prefix = activeConfiguredShortcutChordPrefixForCurrentEvent {
            guard let secondStroke = shortcut.secondStroke,
                  shortcut.firstStroke.isRoutingEquivalent(to: prefix) else {
                return false
            }
            return matchShortcutStroke(event: event, stroke: secondStroke)
        }
        guard !shortcut.hasChord else { return false }
        return matchShortcutStroke(event: event, stroke: shortcut.firstStroke)
    }

    func matchConfiguredShortcut(
        event: NSEvent,
        action: KeyboardShortcutSettings.Action
    ) -> Bool {
        guard shortcutWhenClauseAllows(action: action, event: event) else {
            return false
        }
        return matchConfiguredShortcut(
            event: event,
            shortcut: KeyboardShortcutSettings.shortcut(for: action)
        )
    }

    /// `shortcuts.when` gates opening Search; visible Search owns its toggle so
    /// the auxiliary popover's transient focus context cannot prevent dismissal.
    func globalSearchShortcutWhenClauseAllows(event: NSEvent) -> Bool {
        GlobalSearchCoordinator.shared.isPaletteVisible()
            || shortcutWhenClauseAllows(action: .globalSearch, event: event)
    }

    /// Whether the action's effective `shortcuts.when` predicate permits the event.
    func shortcutWhenClauseAllows(
        action: KeyboardShortcutSettings.Action,
        event: NSEvent
    ) -> Bool {
        KeyboardShortcutSettings.effectiveWhenClause(for: action)
            .evaluate(shortcutEventFocusContext(event).shortcutContext)
    }

    /// Resolves a right-sidebar mode shortcut after applying its effective predicate.
    func rightSidebarModeShortcut(for event: NSEvent) -> RightSidebarMode? {
        let shortcutWindow = resolvedShortcutEventWindow(event)
            ?? event.window
            ?? shortcutRoutingActiveWindow
        if shortcutRoutingShouldBypassForPrintableOptionText(event: event),
           shortcutResponderHasMarkedText(shortcutWindow?.firstResponder) {
            return nil
        }
        return KeyboardShortcutSettingsObserver.shared
            .rightSidebarModeShortcutMatcher.modeShortcut(
                for: event,
                allowingAction: { [self] action in
                    shortcutWhenClauseAllows(action: action, event: event)
                },
                matching: { [self] action, _, event in
                    matchConfiguredShortcut(event: event, action: action)
                }
            )
    }

    func shouldForwardBrowserSurfaceShortcutToTerminal(_ event: NSEvent) -> Bool {
        KeyboardShortcutSettings.Action.allCases.contains {
            $0.shortcutContext.forwardsMenuEquivalentToFocusedTerminal
                && !$0.isBrowserContentShortcut
                && matchConfiguredShortcut(
                    event: event,
                    shortcut: KeyboardShortcutSettings.shortcut(for: $0)
                )
        }
    }

    private func numberedConfiguredShortcutDigit(
        event: NSEvent,
        action: KeyboardShortcutSettings.Action
    ) -> Int? {
        guard !shouldBypassPrefixChordPassThrough(event) else { return nil }
        let shortcut = KeyboardShortcutSettings.shortcut(for: action)
        guard !shortcut.isUnbound else { return nil }
        if let prefix = activeConfiguredShortcutChordPrefixForCurrentEvent {
            guard let secondStroke = shortcut.secondStroke,
                  shortcut.firstStroke.isRoutingEquivalent(to: prefix) else {
                return nil
            }
            return numberedShortcutDigit(event: event, stroke: secondStroke)
        }
        guard !shortcut.hasChord else { return nil }
        return numberedShortcutDigit(event: event, stroke: shortcut.firstStroke)
    }

    func routableNumberedConfiguredShortcutDigit(
        event: NSEvent,
        action: KeyboardShortcutSettings.Action
    ) -> Int? {
        guard let digit = numberedConfiguredShortcutDigit(
            event: event,
            action: action
        ), shortcutWhenClauseAllows(action: action, event: event) else {
            return nil
        }
        return digit
    }

    func matchConfiguredDirectionalShortcut(
        event: NSEvent,
        action: KeyboardShortcutSettings.Action,
        arrowGlyph: String,
        arrowKeyCode: UInt16
    ) -> Bool {
        guard !shouldBypassPrefixChordPassThrough(event),
              shortcutWhenClauseAllows(action: action, event: event) else {
            return false
        }
        let shortcut = KeyboardShortcutSettings.shortcut(for: action)
        guard !shortcut.isUnbound else { return false }
        if let prefix = activeConfiguredShortcutChordPrefixForCurrentEvent {
            guard let secondStroke = shortcut.secondStroke,
                  shortcut.firstStroke.isRoutingEquivalent(to: prefix) else {
                return false
            }
            return matchDirectionalShortcut(
                event: event,
                stroke: secondStroke,
                arrowGlyph: arrowGlyph,
                arrowKeyCode: arrowKeyCode
            )
        }
        guard !shortcut.hasChord else { return false }
        return matchDirectionalShortcut(
            event: event,
            stroke: shortcut.firstStroke,
            arrowGlyph: arrowGlyph,
            arrowKeyCode: arrowKeyCode
        )
    }
}
