public import AppKit
public import CmuxNextDesign

/// One `makeFirstResponder` of a cmux window, judged and recorded: the window asks it whether to
/// refuse the move (guardrail G1, ``UnseenKeyboardGuard``, then the window's own rules), and tells
/// it the move it made, for the focus log (``FocusLog``).
///
/// ```swift
/// let gate = ResponderMoveGate(window: self, log: focusLog, inInputEvent: dispatching, focusModelApplies: applying)
/// if gate.refuses(responder, or: { pageRefuses($0) }) { return false }
/// let accepted = super.makeFirstResponder(responder)
/// if accepted { gate.moved(to: firstResponder) }
/// ```
@MainActor
public struct ResponderMoveGate {
    private let window: NSWindow
    private let log: FocusLog?
    private let before: NSResponder?
    /// A key or click of the person is being dispatched.
    public let inInputEvent: Bool
    private let focusModelApplies: Bool
    /// The route the move came through (nil: a direct `makeFirstResponder`).
    private let route: FocusRoute?

    /// - Parameters:
    ///   - window: The window whose `makeFirstResponder` runs.
    ///   - log: The app's focus log (recorded only while it is on).
    ///   - inInputEvent: A key or click of the person is being dispatched.
    ///   - focusModelApplies: The window's focus model applies its own move.
    ///   - route: The route the move came through (nil: a direct call).
    public init(window: NSWindow, log: FocusLog?, inInputEvent: Bool, focusModelApplies: Bool, route: FocusRoute? = nil) {
        self.window = window
        self.log = log
        before = window.firstResponder
        self.inInputEvent = inInputEvent
        self.focusModelApplies = focusModelApplies
        self.route = route
    }

    /// Whether the window refuses to make `responder` its first responder: G1, a
    /// ``FocusRoute/Origin/system`` move away from where the person types (``takesFromTyping(_:)``),
    /// else `other` (the window's own rule). A refusal is recorded.
    public func refuses(_ responder: NSResponder?, or other: () -> Bool) -> Bool {
        let unseen = UnseenKeyboardGuard().refuses(responder, from: window.firstResponder, inInputEvent: inInputEvent,
                                                   focusModelApplies: focusModelApplies)
        // Its page-window branch (a page view in a Chromium page window) must never fire with in-tree pages on. Only a
        // Chromium page window counts: a refusal in a sheet, popover or other child window is not a page window's.
        if unseen, (responder as? NSView)?.window?.isChromiumPageWindow == true { InTreeRetiredGuards.shared.fired(.unseenKeyboardPageWindow) }
        let refused = unseen || takesFromTyping(responder) || other()
        if refused { log?.responderChanged(in: window, from: before, to: responder, refused: true, byFocusModel: false, route: route) }
        return refused
    }

    /// Whether a move the person did not start (``FocusRoute/Origin/system``, outside a key or click
    /// and outside the focus model's own moves) would take the keys from the text input they typed
    /// into within the last second (``FocusLog/typed(into:within:)``).
    public func takesFromTyping(_ responder: NSResponder?) -> Bool {
        guard route?.origin == .system, !inInputEvent, !focusModelApplies, responder !== before,
              FocusLog.isTypingTarget(before) else { return false }
        return log?.typed(into: before, within: Self.typingGrace) == true
    }

    /// How recent a key makes the person "typing" (s).
    public static let typingGrace: TimeInterval = 1

    /// The window made `responder` its first responder.
    public func moved(to responder: NSResponder?) {
        log?.responderChanged(in: window, from: before, to: responder, refused: false, byFocusModel: focusModelApplies, route: route)
    }
}
