import AppKit
public import CmuxNextInput

/// Command pressed or released over a terminal that does not have focus. A key event goes only to the
/// focused view, so the terminals' one watch hears modifier changes on the app's input tap and tells only
/// the terminal under the pointer (``TerminalLinkPointer``). A terminal tracks itself when the pointer
/// moves over it and untracks when the pointer leaves or the view is hidden, parked or leaves its window.
/// The pointer is over one terminal at a time, so the watch holds one flags subscription for the whole
/// app, and none while no terminal is under the pointer.
///
/// Chrome routes pointer-bound input to the one widget under the pointer the same way, never to every
/// view (content/browser/renderer_host/render_widget_host_input_event_router.cc, the mouse event target).
///
/// The App's composition root makes one with its tap and gives it to every terminal session.
@MainActor public final class TerminalModifierWatch {
    private let input: InputEventTap
    private var subscription: InputSubscription?
    /// The terminal under the pointer now.
    private weak var target: TerminalLinkPointer?

    public init(input: InputEventTap) {
        self.input = input
    }

    /// Whether the watch holds its subscription now.
    public var isWatching: Bool { subscription != nil }

    /// The pointer is over `pointer`'s terminal: modifier changes go to it and to no other terminal.
    /// O(1): every pointer move over the terminal calls it.
    func track(_ pointer: TerminalLinkPointer) {
        target = pointer
        guard subscription == nil else { return }
        subscription = input.subscribe(class: .flags) { [weak self] event in
            guard let self else { return }
            guard let target else { return stop() }
            target.modifiersChanged(event.modifierFlags)
        }
    }

    /// The pointer left `pointer`'s terminal. A terminal the pointer reached since then keeps the watch.
    func untrack(_ pointer: TerminalLinkPointer) {
        guard target === pointer || target == nil else { return }
        stop()
    }

    /// Whether `pointer`'s terminal hears modifier changes now.
    func isTracking(_ pointer: TerminalLinkPointer) -> Bool { target === pointer && isWatching }

    private func stop() {
        target = nil
        subscription?.cancel()
        subscription = nil
    }
}
