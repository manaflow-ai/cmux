import AppKit

extension NSResponder {
    /// Whether this responder chain passes through a browser web view, so
    /// web-extension shortcut commands may claim the event.
    var cmuxChainContainsBrowserWebView: Bool {
        var current: NSResponder? = self
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
}

extension AppDelegate {
    /// Routes an extension command before stale-menu-shortcut suppression.
    func routeWebExtensionCommandForStaleMenuShortcut(
        _ event: NSEvent,
        responder: NSResponder?
    ) -> Bool {
        guard #available(macOS 15.4, *),
              responder?.cmuxChainContainsBrowserWebView == true,
              shortcutEventBrowserPanel(event)?.performWebExtensionCommand(for: event) == true else {
            return false
        }
#if DEBUG
        cmuxDebugLog("app.sendEvent routed web-extension command before stale cmux menu shortcut")
#endif
        return true
    }

    /// Dispatches manifest commands before the Command-only menu-equivalent guard.
    func performBrowserWebExtensionCommandKeyEquivalent(_ event: NSEvent) -> Bool {
        guard #available(macOS 15.4, *),
              browserWebExtensionCommandHasPrimaryModifier(event) else {
            return false
        }
        let panel = shortcutEventBrowserPanel(event)
#if DEBUG
        if panel == nil {
            cmuxDebugLog("browser.webext.command noPanel keyCode=\(event.keyCode)")
        }
#endif
        guard panel?.browserWebExtensionSupport?.hasCommand(for: event) == true,
              shouldOfferBrowserWebExtensionCommand(event) else {
            return false
        }
        return panel?.performWebExtensionCommand(for: event) == true
    }

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
        let focusModePanel = browserFocusModePanelForShortcutEvent(event)
#if DEBUG
        if focusModePanel == nil {
            if let browserPanel = shortcutEventBrowserPanel(event) {
                cmuxDebugLog(
                    "browser.webext.offer focusModeCheck panel=\(browserPanel.id.uuidString.prefix(5)) " +
                    "active=\(browserPanel.isBrowserFocusModeActive ? 1 : 0) " +
                    "webViewFocused=\(isWebViewFocused(browserPanel) ? 1 : 0)"
                )
            } else {
                cmuxDebugLog("browser.webext.offer focusModeCheck noBrowserPanel keyCode=\(event.keyCode)")
            }
        }
#endif
        return shouldOfferBrowserWebExtensionCommand(
            event,
            browserFocusModeActive: focusModePanel != nil
        )
    }

    func shouldOfferBrowserWebExtensionCommand(
        _ event: NSEvent,
        browserFocusModeActive: Bool
    ) -> Bool {
        // Manifest keyboard commands on macOS require a primary modifier. Keep
        // ordinary typing off the all-actions conflict scan in this hot path.
        guard browserWebExtensionCommandHasPrimaryModifier(event) else {
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
#if DEBUG
                    cmuxDebugLog("browser.webext.offer declined action=\(action.rawValue) digit keyCode=\(event.keyCode)")
#endif
                    return false
                }
                continue
            }
            if configuredShortcutClaimsWebExtensionCommand(
                event: event,
                shortcut: KeyboardShortcutSettings.shortcut(for: action)
            ) {
#if DEBUG
                cmuxDebugLog("browser.webext.offer declined action=\(action.rawValue) keyCode=\(event.keyCode)")
#endif
                return false
            }
        }

        let context = preferredMainWindowContextForShortcutRouting(event: event)
        return !configuredCmuxShortcutActions(for: context).contains { action in
            guard let shortcut = action.shortcut else { return false }
            let claims = configuredShortcutClaimsWebExtensionCommand(event: event, shortcut: shortcut)
#if DEBUG
            if claims {
                cmuxDebugLog("browser.webext.offer declined windowAction=\(action.id) keyCode=\(event.keyCode)")
            }
#endif
            return claims
        }
    }

    private func browserWebExtensionCommandHasPrimaryModifier(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return !flags.intersection([.command, .control, .option]).isEmpty
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
