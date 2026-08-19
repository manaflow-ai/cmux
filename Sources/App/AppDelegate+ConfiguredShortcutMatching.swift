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
        guard let stroke = routableConfiguredShortcutStroke(
            event: event,
            shortcut: shortcut
        ) else { return false }
        return matchShortcutStroke(event: event, stroke: stroke)
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
        rightSidebarModeShortcut(
            for: event,
            allowingAction: { [self] action in
                shortcutWhenClauseAllows(action: action, event: event)
            }
        )
    }

    /// Resolves a right-sidebar mode with a caller-supplied context predicate
    /// while retaining the shared configured-shortcut matcher.
    func rightSidebarModeShortcut(
        for event: NSEvent,
        allowingAction: @escaping (KeyboardShortcutSettings.Action) -> Bool
    ) -> RightSidebarMode? {
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
                allowingAction: allowingAction,
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
        let shortcut = KeyboardShortcutSettings.shortcut(for: action)
        guard let stroke = routableConfiguredShortcutStroke(
            event: event,
            shortcut: shortcut
        ) else { return nil }
        return numberedShortcutDigit(event: event, stroke: stroke)
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
        guard let stroke = routableConfiguredShortcutStroke(
            event: event,
            shortcut: KeyboardShortcutSettings.shortcut(for: action)
        ) else { return false }
        return matchDirectionalShortcut(
            event: event,
            stroke: stroke,
            arrowGlyph: arrowGlyph,
            arrowKeyCode: arrowKeyCode
        )
    }

    /// Resolves the one stroke that the ordinary shortcut path may route for
    /// this event. Prefix state, pass-through markers, unbound values, and
    /// chord-vs-single semantics are shared by every surface-specific matcher.
    private func routableConfiguredShortcutStroke(
        event: NSEvent,
        shortcut: StoredShortcut
    ) -> ShortcutStroke? {
        guard !shouldBypassPrefixChordPassThrough(event),
              !shortcut.isUnbound else {
            return nil
        }
        if let prefix = activeConfiguredShortcutChordPrefixForCurrentEvent {
            guard let secondStroke = shortcut.secondStroke,
                  shortcut.firstStroke.isRoutingEquivalent(to: prefix) else {
                return nil
            }
            return secondStroke
        }
        guard !shortcut.hasChord else { return nil }
        return shortcut.firstStroke
    }
}
