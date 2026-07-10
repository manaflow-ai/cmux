import AppKit

/// Whether the responder chain passes through a browser web view, so
/// web-extension shortcut commands (e.g. Bitwarden autofill) may claim the event.
func cmuxRespondersContainBrowserWebView(_ responder: NSResponder?) -> Bool {
    var current: NSResponder? = responder
    while let next = current {
        if next is CmuxWebView { return true }
        if let view = next as? NSView {
            var ancestor: NSView? = view.superview
            while let candidate = ancestor {
                if candidate is CmuxWebView { return true }
                ancestor = candidate.superview
            }
        }
        current = next.nextResponder
    }
    return false
}

/// A stale default (e.g. ⌘⇧L after Open Browser is remapped) is free for
/// web-extension commands like Bitwarden autofill while a browser web
/// view has focus; otherwise the stale-menu-shortcut suppression would eat it.
@MainActor
func cmuxRouteWebExtensionCommandForStaleMenuShortcut(_ event: NSEvent, responder: NSResponder?) -> Bool {
    guard #available(macOS 15.4, *), cmuxRespondersContainBrowserWebView(responder),
          AppDelegate.shared?.shortcutEventBrowserPanel(event)?.performWebExtensionCommand(for: event) == true else {
        return false
    }
#if DEBUG
    cmuxDebugLog("app.sendEvent routed web-extension command before stale cmux menu shortcut")
#endif
    return true
}

/// Manifest commands may use Control or Option, so browser key handling
/// dispatches them before the Command-only cmux menu-equivalent guard.
@MainActor
func cmuxPerformBrowserWebExtensionCommandKeyEquivalent(_ event: NSEvent) -> Bool {
    guard #available(macOS 15.4, *),
          let appDelegate = AppDelegate.shared,
          appDelegate.shouldOfferBrowserWebExtensionCommand(event) else {
        return false
    }
    let panel = appDelegate.shortcutEventBrowserPanel(event)
#if DEBUG
    if panel == nil {
        cmuxDebugLog("browser.webext.command noPanel keyCode=\(event.keyCode)")
    }
#endif
    return panel?.performWebExtensionCommand(for: event) == true
}

extension AppDelegate {
    func matchConfiguredShortcut(event: NSEvent, shortcut: StoredShortcut) -> Bool {
        guard !shortcut.isUnbound else { return false }
        if let prefix = activeConfiguredShortcutChordPrefixForCurrentEvent {
            guard let secondStroke = shortcut.secondStroke,
                  shortcut.firstStroke == prefix else {
                return false
            }
            return matchShortcutStroke(event: event, stroke: secondStroke)
        }
        guard !shortcut.hasChord else { return false }
        return matchShortcutStroke(event: event, stroke: shortcut.firstStroke)
    }

    /// Extension manifest commands run only after configured cmux shortcuts decline the event.
    func shouldOfferBrowserWebExtensionCommand(_ event: NSEvent) -> Bool {
        shouldOfferBrowserWebExtensionCommand(
            event,
            browserFocusModeActive: browserFocusModePanelForShortcutEvent(event) != nil
        )
    }

    func shouldOfferBrowserWebExtensionCommand(
        _ event: NSEvent,
        browserFocusModeActive: Bool
    ) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Manifest keyboard commands on macOS require a primary modifier. Keep
        // ordinary typing off the all-actions conflict scan in this hot path.
        guard !flags.intersection([.command, .control, .option]).isEmpty else {
            return false
        }

        // Browser focus mode already bypasses every configured cmux shortcut at
        // the app-level monitor (the page owns the keyboard), so a binding like
        // the default ⌘⇧L Open Browser cannot fire here anyway. Let manifest
        // commands (e.g. Bitwarden autofill) claim the stroke instead of running
        // a conflict scan against shortcuts that are suspended.
        if browserFocusModeActive {
            return true
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
