/// The focus-follows-mouse gate for a terminal surface view.
///
/// When the pointer enters a terminal surface and focus-follows-mouse is on,
/// the surface wants first-responder so keystrokes route to it. That request is
/// only safe under a precise set of conditions: focus-follows-mouse must be
/// enabled, no mouse button may be pressed (a drag must not steal focus), the
/// app and window must both be active/key, the surface must not already be first
/// responder, and the view must be a visible, laid-out, non-hidden surface that
/// can actually receive focus. This value captures those eight primitive
/// conditions and reduces them to a single boolean decision.
///
/// The decision is a pure function of value-typed inputs with no AppKit, view,
/// or runtime reach, so it lives here beside the other terminal-surface
/// decisions and can be unit-tested without an `NSView`, window, or running app.
/// The app-target surface view reads the live AppKit/`GhosttyApp` state and
/// forwards it through ``shouldRequestFirstResponder(focusFollowsMouseEnabled:pressedMouseButtons:appIsActive:windowIsKey:alreadyFirstResponder:visibleInUI:hasUsableGeometry:hiddenInHierarchy:)``.
public struct TerminalSurfaceMouseFocusPolicy: Sendable {
    /// Whether the focus-follows-mouse setting is enabled.
    public var focusFollowsMouseEnabled: Bool
    /// The bitmask of mouse buttons currently pressed (`NSEvent.pressedMouseButtons`).
    /// A nonzero value means a button is held, so a drag is in progress.
    public var pressedMouseButtons: Int
    /// Whether the application is the active (frontmost) app.
    public var appIsActive: Bool
    /// Whether the surface's window is the key window.
    public var windowIsKey: Bool
    /// Whether the surface is already the window's first responder.
    public var alreadyFirstResponder: Bool
    /// Whether the surface is visible in the UI (not in a hidden portal/split).
    public var visibleInUI: Bool
    /// Whether the surface has a laid-out, non-degenerate geometry that can host focus.
    public var hasUsableGeometry: Bool
    /// Whether the surface (or an ancestor) is hidden in the view hierarchy.
    public var hiddenInHierarchy: Bool

    /// Creates a policy from the eight focus-gate conditions.
    public init(
        focusFollowsMouseEnabled: Bool,
        pressedMouseButtons: Int,
        appIsActive: Bool,
        windowIsKey: Bool,
        alreadyFirstResponder: Bool,
        visibleInUI: Bool,
        hasUsableGeometry: Bool,
        hiddenInHierarchy: Bool
    ) {
        self.focusFollowsMouseEnabled = focusFollowsMouseEnabled
        self.pressedMouseButtons = pressedMouseButtons
        self.appIsActive = appIsActive
        self.windowIsKey = windowIsKey
        self.alreadyFirstResponder = alreadyFirstResponder
        self.visibleInUI = visibleInUI
        self.hasUsableGeometry = hasUsableGeometry
        self.hiddenInHierarchy = hiddenInHierarchy
    }

    /// Whether the surface should request to become first responder for
    /// focus-follows-mouse under the captured conditions.
    ///
    /// The request is granted only when focus-follows-mouse is enabled, no mouse
    /// button is pressed, the app is active, the window is key, the surface is
    /// not already first responder, and the surface is a visible, laid-out,
    /// non-hidden view.
    public var shouldRequestFirstResponder: Bool {
        guard focusFollowsMouseEnabled else { return false }
        guard pressedMouseButtons == 0 else { return false }
        guard appIsActive, windowIsKey else { return false }
        guard !alreadyFirstResponder else { return false }
        guard visibleInUI, hasUsableGeometry, !hiddenInHierarchy else { return false }
        return true
    }

    /// Convenience that builds the policy from the eight conditions and returns
    /// the decision in one call, for sites that do not need to hold the value.
    public static func shouldRequestFirstResponder(
        focusFollowsMouseEnabled: Bool,
        pressedMouseButtons: Int,
        appIsActive: Bool,
        windowIsKey: Bool,
        alreadyFirstResponder: Bool,
        visibleInUI: Bool,
        hasUsableGeometry: Bool,
        hiddenInHierarchy: Bool
    ) -> Bool {
        TerminalSurfaceMouseFocusPolicy(
            focusFollowsMouseEnabled: focusFollowsMouseEnabled,
            pressedMouseButtons: pressedMouseButtons,
            appIsActive: appIsActive,
            windowIsKey: windowIsKey,
            alreadyFirstResponder: alreadyFirstResponder,
            visibleInUI: visibleInUI,
            hasUsableGeometry: hasUsableGeometry,
            hiddenInHierarchy: hiddenInHierarchy
        ).shouldRequestFirstResponder
    }
}
