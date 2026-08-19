import AppKit
import CmuxSettings

extension AppDelegate {
    /// Resolves the window identity shared by every prefix pass-through seam.
    /// AppKit can omit `event.window` while still carrying a valid event number;
    /// the configured shortcut resolver provides the same main-window fallback
    /// used by ordinary shortcut routing before raw event/window values.
    func prefixChordWindowNumber(
        for event: NSEvent,
        fallbackWindow: NSWindow? = nil
    ) -> Int {
        if let window = event.window {
            return window.windowNumber
        }
        if let configured = configuredShortcutChordWindowNumber(for: event) {
            return configured
        }
        if let fallbackWindow {
            return fallbackWindow.windowNumber
        }
        return event.windowNumber > 0 ? event.windowNumber : 0
    }

    /// Returns whether this event was explicitly marked as an unmatched
    /// prefix suffix. All secondary shortcut surfaces use this seam before
    /// attempting their own legacy matching so a mismatch remains literal.
    func shouldBypassPrefixChordPassThrough(_ event: NSEvent) -> Bool {
        guard prefixChordPassThroughCoordinator.hasMarkers else { return false }
        let windowNumber = prefixChordWindowNumber(for: event)
        return prefixChordPassThroughCoordinator.shouldBypass(
            event,
            windowNumber: windowNumber
        )
    }

    /// Offers the event to the optional leader layer. `nil` means ordinary
    /// shortcut routing should continue; a Boolean is the local-monitor return
    /// value for an event that was consumed or must be passed through without
    /// another cmux/menu attempt.
    func routePrefixChordEvent(_ event: NSEvent) -> Bool? {
        // A mismatch marker outlives the first local-monitor offer until the
        // complete AppKit sendEvent/key-equivalent stack unwinds. Check it
        // before the cached prefix state: a settings edit can disable the
        // layer in that tiny interval, and the already-declared pass-through
        // must still prevent a later cmux matcher from stealing the byte.
        let hasPassThroughMarker = event.type == .keyDown
            && prefixChordPassThroughCoordinator.hasMarkers
            && shouldBypassPrefixChordPassThrough(event)
        guard shortcutPrefixChordCoordinator.isEnabled else {
            return hasPassThroughMarker ? false : nil
        }

        if hasPassThroughMarker {
            // The event was already resolved as an unmatched suffix. Do not
            // offer it to the state machine again, even if a lifecycle or
            // settings transition changed the cached prefix configuration.
            return false
        }

        if prefixChordEventShouldBypass(event) {
            switch shortcutPrefixChordCoordinator.offerBypassed(event) {
            case .consume:
                return true
            case .mismatchPassThrough:
                if event.type == .keyDown {
                    markPrefixChordPassThrough(event)
                }
                return false
            case .duplicatePassThrough:
                return false
            case .passThrough, .execute:
                return nil
            }
        }

        switch shortcutPrefixChordCoordinator.offer(event) {
        case .consume:
            return true
        case .mismatchPassThrough:
            if event.type == .keyDown {
                markPrefixChordPassThrough(event)
            }
            return false
        case .duplicatePassThrough:
            return false
        case let .execute(binding):
            // The coordinator consumed the leader and resolved a unique
            // suffix. Execute through the same dispatcher used by ordinary
            // key equivalents while retaining the resolved prefix marker for
            // the duration of that dispatch. Focus-owned actions (viewers,
            // text boxes, and checklist panes) are handled by the shared
            // local-action seam when the generic dispatcher has no branch.
            guard executeResolvedPrefixChordBinding(binding, event: event) else {
                // A focus/action boundary may change between the leader and
                // suffix. The router had a unique table entry, but if the
                // shared executor cannot perform it now, fail closed and let
                // the suffix reach the focused responder unchanged. The
                // marker also protects the later AppKit replay seam.
                if event.type == .keyDown {
                    markPrefixChordPassThrough(event)
                }
                return false
            }
            return true
        case .passThrough:
            return nil
        }
    }

    private func markPrefixChordPassThrough(_ event: NSEvent) {
        let windowNumber = prefixChordWindowNumber(for: event)
        prefixChordPassThroughCoordinator.mark(event, windowNumber: windowNumber)
    }

    /// Prefix routing must stand down for modal interaction and active IME
    /// composition. These are the same ownership boundaries used by the normal
    /// shortcut dispatcher, kept in one seam so an armed layer cannot swallow
    /// text intended for a sheet, alert, or input method.
    private func prefixChordEventShouldBypass(_ event: NSEvent) -> Bool {
        // System-defined media events are deliberately not an ownership
        // bypass: recognized media keys can be valid suffixes, while unknown
        // system-defined events cancel an armed prefix in the coordinator.
        // Key-up/flags events remain outside the layer and must not perturb
        // pending state.
        if event.type == .systemDefined { return false }
        guard event.type == .keyDown else { return true }
        let window = resolvedShortcutEventWindow(event)
            ?? event.window
            ?? shortcutRoutingActiveWindow
        if NSApp.modalWindow != nil || window?.attachedSheet != nil {
            return true
        }

        // Browser focus mode gives the page exclusive ownership of key events,
        // including Escape's two-press exit gesture. Do not let a cmux leader
        // consume either press while the focused responder is the WebView.
        if let browserPanel = shortcutEventBrowserPanel(event),
           browserPanel.isBrowserFocusModeActive,
           let responder = window?.firstResponder as? NSView,
           let webViewWindow = browserPanel.webView.window,
           webViewWindow === window,
           (responder === browserPanel.webView || responder.isDescendant(of: browserPanel.webView)) {
            return true
        }

        // Ordinary text responders do not automatically own a configured
        // prefix. The coordinator builds its table from the action's effective
        // `when` clause, so a chord remains available in a text field when an
        // action explicitly permits that context (including command-palette
        // actions). Only an active IME composition is an unconditional text
        // ownership boundary below.
        return shortcutResponderHasMarkedText(window?.firstResponder)
            || window?.firstResponder.cmuxStrictOwningGhosttyView()?.hasMarkedText() == true
    }
}
