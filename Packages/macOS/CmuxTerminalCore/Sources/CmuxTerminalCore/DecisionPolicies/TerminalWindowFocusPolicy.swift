/// Pure focus-follows-mouse gating for a terminal surface view.
///
/// This is the terminal-domain home of `GhosttyNSView.shouldRequestFirstResponderForMouseFocus`.
/// It carries no state and reads no AppKit handles: the view resolves its live
/// AppKit conditions (app active, key window, first-responder, hierarchy
/// visibility, usable geometry) and passes them in as booleans so the decision
/// stays a deterministic, testable value computation.
public enum TerminalWindowFocusPolicy: Sendable {
    /// Whether a mouse-over a terminal surface should claim first responder.
    ///
    /// Focus-follows-mouse only fires when enabled, no mouse buttons are held,
    /// the app is active and its window is key, the surface is not already first
    /// responder, and the surface is visibly hosted with usable geometry.
    public static func shouldRequestFirstResponderForMouseFocus(
        focusFollowsMouseEnabled: Bool,
        pressedMouseButtons: Int,
        appIsActive: Bool,
        windowIsKey: Bool,
        alreadyFirstResponder: Bool,
        visibleInUI: Bool,
        hasUsableGeometry: Bool,
        hiddenInHierarchy: Bool
    ) -> Bool {
        guard focusFollowsMouseEnabled else { return false }
        guard pressedMouseButtons == 0 else { return false }
        guard appIsActive, windowIsKey else { return false }
        guard !alreadyFirstResponder else { return false }
        guard visibleInUI, hasUsableGeometry, !hiddenInHierarchy else { return false }
        return true
    }
}
