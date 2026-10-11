import AppKit

/// Decides when a JS sidebar's autofocus text field may take keyboard focus.
///
/// Autofocus only moves focus the user already gave the sidebar: right after a
/// click in this sidebar (a button, row tap, double-click or menu item), or
/// while one of this sidebar's own fields holds focus. Anything else, such as
/// a field mounted by a data update while the user types in a terminal,
/// mounts unfocused. Without this rule sidebar code could mount a hidden field
/// at any moment and receive keystrokes (passwords included) meant for the
/// terminal through its `onEdit` handler.
///
/// One gate belongs to one sidebar's ``SceneStore``, so a field in one
/// sidebar never counts as focus for another.
@MainActor
final class SceneAutofocusGate {
    /// Host events that count as a user click in the sidebar. Context-menu
    /// items dispatch as `tap`. Typing (`edit`), `submit` (which also fires on
    /// focus loss), `cancel`, and drag feedback do not.
    nonisolated static let gestureEvents: Set<String> = ["tap", "doubletap"]

    /// How long after a click a mounted field may still take focus. The field
    /// mounts in the render that follows the click, normally within the same
    /// run-loop turn; the margin covers a busy main thread.
    nonisolated static let gestureWindow: Duration = .seconds(1)

    private let now: () -> ContinuousClock.Instant
    private var lastGestureAt: ContinuousClock.Instant?

    /// Creates a gate with no recorded click.
    ///
    /// - Parameter now: The clock reading; tests inject one to step past
    ///   ``gestureWindow``.
    init(now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.now = now
    }

    /// Records a host event delivered to this sidebar; only
    /// ``gestureEvents`` open the focus window.
    func noteEvent(_ event: String) {
        guard Self.gestureEvents.contains(event) else { return }
        lastGestureAt = now()
    }

    /// Whether one of this sidebar's fields may become first responder of
    /// `window` now.
    ///
    /// A recent click authorizes a single focus move and is spent by it;
    /// focus already inside this sidebar may move between its fields freely.
    func allowsFocus(in window: NSWindow) -> Bool {
        holdsFocus(in: window) || consumeRecentGesture()
    }

    /// Spends the last click if it happened within ``gestureWindow``.
    func consumeRecentGesture() -> Bool {
        guard let lastGestureAt else { return false }
        self.lastGestureAt = nil
        return lastGestureAt.duration(to: now()) <= Self.gestureWindow
    }

    /// Whether `window`'s keyboard focus is in one of this sidebar's fields.
    private func holdsFocus(in window: NSWindow) -> Bool {
        var responder = window.firstResponder
        // An editing text field's first responder is its field editor.
        if let editor = responder as? NSText, let owner = editor.delegate as? NSTextField {
            responder = owner
        }
        guard let field = responder as? SceneTextField else { return false }
        return field.autofocusGate === self
    }
}
