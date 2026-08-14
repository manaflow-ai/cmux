import AppKit
import CmuxSettings
import CmuxTerminal

extension NSEvent {
    var cmuxIsUndoRedoCommandEquivalent: Bool {
        let normalizedFlags = modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        return type == .keyDown
            && (normalizedFlags == [.command] || normalizedFlags == [.command, .shift])
            && KeyboardLayout.normalizedCharacters(for: self) == "z"
    }
}

/// Identity of a key event currently being force-dispatched into a responder's
/// `keyDown(with:)` by `NSWindow.cmux_performKeyEquivalent(with:)`.
///
/// Forwarding keyDown can re-enter `performKeyEquivalent` with the same event
/// while the dispatch is still on the stack: WebKit replays unhandled keys
/// through the responder chain, and on macOS 26 `-[NSWindow keyDown:]`
/// re-enters `performKeyEquivalent`. Without a replay guard at the dispatch
/// chokepoint the same event ping-pongs between the swizzle and the focused
/// responder until the main-thread stack overflows
/// (https://github.com/manaflow-ai/cmux/issues/5887).
///
/// Identity is the event's stable field tuple rather than object identity so
/// the guard still holds if AppKit/WebKit re-deliver the event as an equal
/// copy. Key autorepeat produces distinct events (fresh timestamps), so
/// repeat typing is never throttled. The dispatching window's number is part
/// of the identity so windows cannot suppress each other's dispatches.
private struct CmuxForceDispatchedKeyEventIdentity: Hashable {
    let windowNumber: Int
    let eventType: UInt
    let keyCode: UInt16
    let modifierFlags: UInt
    let timestamp: TimeInterval
}

/// Events whose force-dispatch is currently on the main-thread stack.
/// Main-thread only (key-event dispatch); entries are stack-scoped, inserted
/// before `keyDown(with:)` and removed when the dispatch unwinds, so WebKit's
/// legitimate replay of an unhandled key (which arrives after the original
/// dispatch has fully unwound) is still force-dispatched normally.
private var cmuxInFlightForceDispatchedKeyEventIdentities = Set<CmuxForceDispatchedKeyEventIdentity>()

/// A suffix that did not match the prefix table must bypass cmux's later
/// menu/performKeyEquivalent pass. The local monitor returns the original
/// event so AppKit can deliver it to the focused responder, but AppKit may
/// first replay that same event through `performKeyEquivalent`; this marker
/// keeps that replay from stealing the terminal byte.
@MainActor
enum CmuxPrefixChordPassThroughGuard {
    private static var ledger = ShortcutPrefixChordPassThroughLedger()
    /// A window's `sendEvent` call can wrap one or more key-equivalent offers
    /// before it finally delivers `keyDown` to the focused responder. Retain
    /// the marker for that complete dispatch, not merely the menu-equivalent
    /// phase, so a responder-local shortcut cannot steal the suffix afterward.
    private static var eventDispatchDepth: [ShortcutPrefixChordEventIdentity: Int] = [:]
    /// Nested `performKeyEquivalent` calls are common when WebKit or an
    /// AppKit responder re-offers the same event. Keep a bypass marker alive
    /// until the outermost offer returns; consuming it at the first window
    /// chokepoint would let a nested responder steal the terminal byte.
    private static var keyEquivalentDepth: [ShortcutPrefixChordEventIdentity: Int] = [:]

    /// Cheap fast-path probe used by the optional prefix router. Most events
    /// arrive with an empty ledger (especially while the feature is disabled),
    /// so callers can avoid resolving a window identity and walking AppKit
    /// focus state merely to discover that no marker exists.
    static var hasMarkers: Bool { ledger.count > 0 }

    static func mark(_ event: NSEvent, windowNumber: Int) {
        ledger.mark(identity(for: event, windowNumber: windowNumber))
    }

    static func shouldBypass(_ event: NSEvent, windowNumber: Int) -> Bool {
        ledger.contains(identity(for: event, windowNumber: windowNumber))
    }

    /// Begins one complete window event dispatch.
    static func beginEvent(_ event: NSEvent, windowNumber: Int) {
        let eventIdentity = identity(for: event, windowNumber: windowNumber)
        eventDispatchDepth[eventIdentity, default: 0] += 1
    }

    /// Begins one key-equivalent offer and reports whether the event is marked
    /// for pass-through. Depth is tracked even when no marker exists yet: a
    /// nested route can discover a mismatch after the outer offer has started,
    /// and that marker must still survive until the outer offer unwinds.
    static func beginKeyEquivalent(_ event: NSEvent, windowNumber: Int) -> Bool {
        let eventIdentity = identity(for: event, windowNumber: windowNumber)
        keyEquivalentDepth[eventIdentity, default: 0] += 1
        return ledger.contains(eventIdentity)
    }

    /// Ends one key-equivalent offer. The marker is consumed only when the
    /// outermost nested offer has returned.
    static func endKeyEquivalent(_ event: NSEvent, windowNumber: Int) {
        let eventIdentity = identity(for: event, windowNumber: windowNumber)
        guard let depth = keyEquivalentDepth[eventIdentity] else {
            return
        }
        if depth > 1 {
            keyEquivalentDepth[eventIdentity] = depth - 1
        } else {
            keyEquivalentDepth.removeValue(forKey: eventIdentity)
            if eventDispatchDepth[eventIdentity] == nil {
                ledger.consume(eventIdentity)
            }
        }
    }

    /// Finishes one complete window event dispatch. The outermost dispatch
    /// consumes the marker after responder delivery; a still-active nested
    /// key-equivalent offer owns cleanup when its own stack unwinds.
    static func finishEvent(_ event: NSEvent, windowNumber: Int) {
        let eventIdentity = identity(for: event, windowNumber: windowNumber)
        guard let depth = eventDispatchDepth[eventIdentity] else { return }
        if depth > 1 {
            eventDispatchDepth[eventIdentity] = depth - 1
        } else {
            eventDispatchDepth.removeValue(forKey: eventIdentity)
            if keyEquivalentDepth[eventIdentity] == nil {
                ledger.consume(eventIdentity)
            }
        }
    }

    /// Drops markers that can no longer be replayed after a settings/lifecycle
    /// transition.  Event numbers are normally unique, but synthetic events
    /// may reuse a structural identity across those transitions.
    static func reset() {
        ledger.removeAll()
        eventDispatchDepth.removeAll()
        keyEquivalentDepth.removeAll()
    }

    private static func identity(
        for event: NSEvent,
        windowNumber: Int
    ) -> ShortcutPrefixChordEventIdentity {
        ShortcutPrefixChordEventIdentity(
            eventNumber: event.eventNumber >= 0 ? UInt64(event.eventNumber) : 0,
            windowID: windowNumber == 0 ? nil : windowNumber,
            keyCode: event.keyCode,
            modifierFlags: event.modifierFlags.rawValue,
            timestamp: event.timestamp
        )
    }
}

/// Retains an unmatched prefix suffix marker for one complete
/// ``NSWindow.sendEvent(_:)`` dispatch, including nested key-equivalent offers.
@MainActor
struct CmuxPrefixChordEventDispatchScope {
    private let event: NSEvent
    private let windowNumber: Int
    private let isActive: Bool

    static func begin(event: NSEvent, window: NSWindow) -> Self {
        let isActive = event.type == .keyDown
            && (CmuxPrefixChordPassThroughGuard.hasMarkers
                || AppDelegate.shared?.shortcutPrefixChordCoordinator.isEnabled == true)
        if isActive {
            CmuxPrefixChordPassThroughGuard.beginEvent(
                event,
                windowNumber: window.windowNumber
            )
        }
        return Self(
            event: event,
            windowNumber: window.windowNumber,
            isActive: isActive
        )
    }

    func finish() {
        guard isActive else { return }
        CmuxPrefixChordPassThroughGuard.finishEvent(
            event,
            windowNumber: windowNumber
        )
    }
}

/// Retains an unmatched suffix marker across nested AppKit
/// `performKeyEquivalent` offers for the same event.
@MainActor
struct CmuxPrefixChordKeyEquivalentScope {
    private let event: NSEvent
    private let windowNumber: Int
    private let isActive: Bool
    let shouldBypass: Bool

    static func begin(event: NSEvent, window: NSWindow) -> Self {
        let isActive = event.type == .keyDown
            && (AppDelegate.shared?.shortcutPrefixChordCoordinator.isEnabled == true
                || CmuxPrefixChordPassThroughGuard.hasMarkers)
        let shouldBypass: Bool
        if isActive {
            _ = CmuxPrefixChordPassThroughGuard.beginKeyEquivalent(
                event,
                windowNumber: window.windowNumber
            )
            shouldBypass = CmuxPrefixChordPassThroughGuard.shouldBypass(
                event,
                windowNumber: window.windowNumber
            )
        } else {
            shouldBypass = false
        }
        return Self(
            event: event,
            windowNumber: window.windowNumber,
            isActive: isActive,
            shouldBypass: shouldBypass
        )
    }

    func finish() {
        guard isActive else { return }
        CmuxPrefixChordPassThroughGuard.endKeyEquivalent(
            event,
            windowNumber: windowNumber
        )
    }
}

@MainActor
extension NSWindow {
    /// Offers synthetic/key-equivalent events that can enter `sendEvent`
    /// without first traversing the app-local monitor.
    func cmuxRoutePrefixChordBeforeKeyDownDelivery(
        _ event: NSEvent,
        appDelegate: AppDelegate
    ) -> Bool {
        guard appDelegate.shortcutPrefixChordCoordinator.isEnabled,
              let prefixResult = appDelegate.routePrefixChordEvent(event) else {
            return false
        }
        return prefixResult
    }

    /// Resolves the prefix layer before menus and responder-local equivalents.
    /// A non-nil result is the value `performKeyEquivalent` must return.
    func cmuxRoutePrefixChordKeyEquivalent(
        _ event: NSEvent,
        appDelegate: AppDelegate
    ) -> Bool? {
        guard event.type == .keyDown,
              appDelegate.shortcutPrefixChordCoordinator.isEnabled else {
            return nil
        }
        if let prefixResult = appDelegate.routePrefixChordEvent(event) {
            return prefixResult
        }
        return appDelegate.handleConfiguredShortcutKeyEquivalent(event) ? true : nil
    }
}

extension NSWindow {
    func cmuxRouteUndoRedoCommandEquivalentAwayFromAppKit(
        _ event: NSEvent,
        terminalView: GhosttyNSView?,
        webView: CmuxWebView?,
        browserWebKitKeyDownReentry: Bool
    ) -> Bool {
        guard event.cmuxIsUndoRedoCommandEquivalent,
              !cmuxFirstResponderPreservesLocalUndoRedo,
              !cmuxIsLikelyWebInspectorResponder(firstResponder) else {
            return false
        }
        if let terminalView {
            if terminalView.performKeyEquivalentAfterMenuMiss(with: event) {
#if DEBUG
                cmuxDebugLog("  -> undo/redo routed to terminal before AppKit menu")
#endif
                return true
            }
            if cmuxForceDispatchKeyDownOnce(event, to: terminalView, reason: "terminal undo/redo") {
#if DEBUG
                cmuxDebugLog("  -> undo/redo keyDown fallback routed to terminal")
#endif
                return true
            }
            return true
        }
        if let webView {
            if browserWebKitKeyDownReentry {
#if DEBUG
                cmuxDebugLog("  -> undo/redo browser reentry suppressed before AppKit menu")
#endif
                return true
            }
            if webView.performKeyEquivalent(with: event) {
#if DEBUG
                cmuxDebugLog("  -> undo/redo routed to browser before AppKit menu")
#endif
                return true
            }
            if cmuxForceDispatchKeyDownOnce(event, to: webView, reason: "browser undo/redo") {
#if DEBUG
                cmuxDebugLog("  -> undo/redo keyDown fallback routed to browser")
#endif
                return true
            }
            // Do not fall through to AppKit Undo from generic browser focus:
            // that is the stale NSUndoManager path this router avoids. Focused
            // editable AppKit responders and Web Inspector are exempted above.
            return true
        }
        return false
    }

    private var cmuxFirstResponderPreservesLocalUndoRedo: Bool {
        guard let responder = firstResponder else { return false }
        if let textView = responder as? NSTextView {
            return textView.isEditable || textView.isFieldEditor
        }
        if let textField = responder as? NSTextField {
            return textField.isEditable
        }
        return false
    }

    /// Single chokepoint for every direct `keyDown(with:)` force-dispatch made
    /// by `cmux_performKeyEquivalent(with:)`.
    ///
    /// Dispatches `event` into `target`'s `keyDown(with:)` unless the same
    /// event is already being force-dispatched lower on this window's call
    /// stack, and returns whether the dispatch happened. Callers that get
    /// `false` back must decline the event (fall through to default AppKit
    /// handling) instead of dispatching themselves; re-dispatching the same
    /// in-flight event is the infinite key-routing loop from
    /// https://github.com/manaflow-ai/cmux/issues/5887.
    func cmuxForceDispatchKeyDownOnce(
        _ event: NSEvent,
        to target: NSResponder,
        reason: @autoclosure () -> String
    ) -> Bool {
        let identity = CmuxForceDispatchedKeyEventIdentity(
            windowNumber: self.windowNumber,
            eventType: event.type.rawValue,
            keyCode: event.keyCode,
            modifierFlags: event.modifierFlags.rawValue,
            timestamp: event.timestamp
        )
        guard !cmuxInFlightForceDispatchedKeyEventIdentities.contains(identity) else {
#if DEBUG
            cmuxDebugLog("  → \(reason()) reentry; declining force-dispatch of in-flight key event")
#endif
            return false
        }
        cmuxInFlightForceDispatchedKeyEventIdentities.insert(identity)
        defer { cmuxInFlightForceDispatchedKeyEventIdentities.remove(identity) }
#if DEBUG
        cmuxDebugLog("  → \(reason()) routed to firstResponder.keyDown")
#endif
        target.keyDown(with: event)
        return true
    }
}
