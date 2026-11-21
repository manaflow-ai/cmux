public import AppKit

/// The window's rule that code cannot hand the keyboard to a view the person cannot see
/// (plans/cmux-next/focus-loss-AUDIT.md, guardrail G1).
///
/// Every keyboard move of a cmux window goes through its `makeFirstResponder`. Outside a key or
/// click the person made, and outside the focus model's own moves, the window refuses to move the
/// keyboard away from a view that shows to one that does not: a hidden view, or one parked outside
/// the window (a prewarmed page in `PageOffscreenParking`, 100,000 points off the content). Such a
/// move left the person typing into a page no one could see while the window stayed key (Lawrence
/// 2026-11-15: "cmux window stays in focus, but the text input area is out of focus").
///
/// A zero-size view is not "outside": a key catcher may have no area. A move from the window
/// itself or from nothing takes nothing from the person, so it is allowed.
///
/// ```swift
/// if UnseenKeyboardGuard().refuses(responder, from: firstResponder, inInputEvent: false, focusModelApplies: false) {
///     return false
/// }
/// ```
public struct UnseenKeyboardGuard {
    public init() {}

    /// Whether the window refuses to move its keyboard from `current` to `responder`.
    ///
    /// - Parameters:
    ///   - responder: The responder asked for.
    ///   - current: The window's first responder now.
    ///   - inInputEvent: A key or click of the person is being dispatched.
    ///   - focusModelApplies: The window's focus model is applying its own move.
    /// - Returns: True when the move would take the keyboard from a shown view to an unseen one.
    @MainActor
    public func refuses(_ responder: NSResponder?, from current: NSResponder?, inInputEvent: Bool, focusModelApplies: Bool) -> Bool {
        guard !inInputEvent, !focusModelApplies, let target = responder as? NSView, let window = target.window else { return false }
        guard let current = current as? NSView, current !== target, current.window === window, shows(current) else { return false }
        return !shows(target)
    }

    /// Whether the person can see `view`: no hidden ancestor, and a view with an area has some
    /// of it inside its window's content. Views do not clip to their bounds by default, so
    /// `visibleRect` of a parked view is not empty: the view's rect in the window is compared with
    /// the content's.
    @MainActor
    public func shows(_ view: NSView) -> Bool {
        if view.isHiddenOrHasHiddenAncestor { return false }
        if view.bounds.isEmpty { return true }
        guard let window = view.window, let content = window.contentView else { return true }
        let rect = view.convert(view.bounds, to: nil)
        return rect.intersects(content.convert(content.bounds, to: nil)) && !view.visibleRect.isEmpty
    }
}
