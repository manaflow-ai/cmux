import AppKit

extension AppDelegate {
    /// Extension manifest commands run only after configured cmux shortcuts decline the event.
    func shouldOfferBrowserWebExtensionCommand(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Manifest keyboard commands on macOS require a primary modifier. Keep
        // ordinary typing off the all-actions conflict scan in this hot path.
        guard !flags.intersection([.command, .control, .option]).isEmpty else {
            return false
        }

        let shortcutContext = shortcutEventFocusContext(event).shortcutContext
        for action in KeyboardShortcutSettings.Action.allCases {
            guard action != .showHideAllWindows,
                  action != .globalSearch,
                  !action.isBrowserContentShortcut,
                  KeyboardShortcutSettings.effectiveWhenClause(for: action).evaluate(shortcutContext) else {
                continue
            }
            if action.usesNumberedDigitMatching {
                if numberedConfiguredShortcutDigit(event: event, action: action) != nil {
                    return false
                }
                continue
            }
            if configuredShortcutClaimsWebExtensionCommand(
                event: event,
                shortcut: KeyboardShortcutSettings.shortcut(for: action)
            ) {
                return false
            }
        }

        let context = preferredMainWindowContextForShortcutRouting(event: event)
        return !configuredCmuxShortcutActions(for: context).contains { action in
            guard let shortcut = action.shortcut else { return false }
            return configuredShortcutClaimsWebExtensionCommand(event: event, shortcut: shortcut)
        }
    }

    private func configuredShortcutClaimsWebExtensionCommand(
        event: NSEvent,
        shortcut: StoredShortcut
    ) -> Bool {
        guard !shortcut.isUnbound else { return false }
        if activeConfiguredShortcutChordPrefixForCurrentEvent == nil, shortcut.hasChord {
            return matchShortcutStroke(event: event, stroke: shortcut.firstStroke)
        }
        return matchConfiguredShortcut(event: event, shortcut: shortcut)
    }
}
