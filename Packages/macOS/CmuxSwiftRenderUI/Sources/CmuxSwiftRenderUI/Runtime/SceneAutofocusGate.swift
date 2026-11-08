import AppKit

/// Decides when a JS sidebar's autofocus text field may take keyboard focus.
///
/// Autofocus only moves focus the user already gave the sidebar:
///
/// - **A click mounted it.** The field's node was created while the host was
///   delivering a click in this sidebar (a button, row tap, double-click or
///   menu item), it asks within ``gestureWindow`` of that click, and every
///   window's keyboard focus is still where it was when the user clicked. A
///   click whose action moved focus elsewhere (selecting a workspace focuses
///   its terminal) authorizes nothing. One click spends at most one focus
///   move.
/// - **The sidebar already has focus.** One of this sidebar's own fields is
///   first responder, so focus may move between its fields.
///
/// Anything else, such as a field that a data update mounts while the user
/// types in a terminal, mounts unfocused. Without this rule sidebar code
/// could mount a hidden field at any moment and receive keystrokes
/// (passwords included) meant for the terminal through its `onEdit` handler.
///
/// One gate belongs to one sidebar's ``SceneStore``, so a field in one
/// sidebar never counts as focus for another.
@MainActor
final class SceneAutofocusGate {
    /// Host events that count as a user click in the sidebar. Context-menu
    /// items dispatch as `tap`. Typing (`edit`), `submit` (which also fires on
    /// focus loss), `cancel`, and drag feedback do not.
    nonisolated static let gestureEvents: Set<String> = ["tap", "doubletap"]

    /// How long after a click a field it created may still take focus. The
    /// field mounts in the render that follows the click, normally within the
    /// same run-loop turn; the margin covers a busy main thread.
    nonisolated static let gestureWindow: Duration = .seconds(1)

    /// Where one window's keyboard focus was when the user clicked.
    private struct FocusSnapshot {
        weak var window: NSWindow?
        weak var responder: NSResponder?
    }

    /// The last click and what it may authorize.
    private struct Gesture {
        let at: ContinuousClock.Instant
        let focus: [FocusSnapshot]
        var createdNodeIds: Set<String> = []
    }

    private let now: () -> ContinuousClock.Instant
    private let windows: @MainActor () -> [NSWindow]
    private var gesture: Gesture?
    private var dispatchingGesture = false

    /// Creates a gate with no recorded click.
    ///
    /// - Parameters:
    ///   - now: The clock reading; tests inject one to step past
    ///     ``gestureWindow``.
    ///   - windows: The windows whose focus a click snapshots; defaults to
    ///     the app's windows.
    init(
        now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now },
        windows: @escaping @MainActor () -> [NSWindow] = { NSApp?.windows ?? [] }
    ) {
        self.now = now
        self.windows = windows
    }

    /// Delivers one host event through `dispatch`. For a click
    /// (``gestureEvents``) it snapshots every window's focus first and
    /// records the nodes the handler creates, which are the only ones the
    /// click may focus. Any other event drops a pending click.
    func deliver(_ event: String, dispatch: () -> Void) {
        guard Self.gestureEvents.contains(event) else {
            if event != "dragChange" { gesture = nil }
            dispatch()
            return
        }
        gesture = Gesture(
            at: now(),
            focus: windows().map { FocusSnapshot(window: $0, responder: $0.firstResponder) }
        )
        dispatchingGesture = true
        defer { dispatchingGesture = false }
        dispatch()
    }

    /// Records a scene node created by the program; only nodes created while
    /// a click is being delivered may take focus for it.
    func noteNodeCreated(_ nodeId: String) {
        guard dispatchingGesture else { return }
        gesture?.createdNodeIds.insert(nodeId)
    }

    /// Whether the field for `nodeId` may become first responder of `window`
    /// now. A click authorization is spent by asking, granted or not.
    func allowsFocus(nodeId: String, in window: NSWindow) -> Bool {
        if holdsFocus(in: window) { return true }
        guard let gesture else { return false }
        self.gesture = nil
        return gesture.createdNodeIds.contains(nodeId)
            && gesture.at.duration(to: now()) <= Self.gestureWindow
            && Self.focusUnchanged(since: gesture.focus, in: window)
    }

    /// True when `window` was snapshotted at the click and its first
    /// responder is still the same object.
    private static func focusUnchanged(since snapshot: [FocusSnapshot], in window: NSWindow) -> Bool {
        guard let entry = snapshot.first(where: { $0.window === window }) else { return false }
        return entry.responder === window.firstResponder
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
