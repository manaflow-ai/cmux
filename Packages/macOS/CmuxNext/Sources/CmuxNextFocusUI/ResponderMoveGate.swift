public import AppKit

/// One `makeFirstResponder` of a cmux window, judged and recorded: the window asks it whether to
/// refuse the move (the window's own rules), and tells
/// it the move it made, for the focus log (``FocusLog``). Off, the log costs one tunable read.
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

    /// - Parameters:
    ///   - window: The window whose `makeFirstResponder` runs.
    ///   - log: The app's focus log (recorded only while it is on).
    ///   - inInputEvent: A key or click of the person is being dispatched.
    ///   - focusModelApplies: The window's focus model applies its own move.
    public init(window: NSWindow, log: FocusLog?, inInputEvent: Bool, focusModelApplies: Bool) {
        self.window = window
        self.log = log?.isEnabled == true ? log : nil
        before = self.log == nil ? nil : window.firstResponder
        self.inInputEvent = inInputEvent
        self.focusModelApplies = focusModelApplies
    }

    /// Whether the window refuses to make `responder` its first responder: `other` (the window's
    /// own rule). A refusal is recorded.
    public func refuses(_ responder: NSResponder?, or other: () -> Bool) -> Bool {
        let refused = other()
        if refused { log?.responderChanged(in: window, from: before, to: responder, refused: true, byFocusModel: false) }
        return refused
    }

    /// The window made `responder` its first responder.
    public func moved(to responder: NSResponder?) {
        log?.responderChanged(in: window, from: before, to: responder, refused: false, byFocusModel: focusModelApplies)
    }
}
