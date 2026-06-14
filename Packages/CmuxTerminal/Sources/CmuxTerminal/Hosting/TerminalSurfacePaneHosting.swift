public import AppKit

/// The pane container view that hosts a ``TerminalSurface``'s native view
/// (scrollbar, overlays, focus bookkeeping).
///
/// The concrete container (`GhosttySurfaceScrollView`) lives above this
/// package in the view layer; the surface model holds it through this seam
/// plus the `NSView` superclass surface (window, frame, autoresizing).
@MainActor
public protocol TerminalSurfacePaneHosting: NSView {
    /// Attaches a surface model to this container, creating or adopting the
    /// runtime surface when the view is in a window.
    func attachSurface(_ surface: TerminalSurface)

    /// Cancels any queued focus request for this container.
    func cancelFocusRequest()

    /// Records whether the pane is visible in the UI (drives occlusion and
    /// renderer reclamation).
    func setVisibleInUI(_ visible: Bool)

    /// Records whether the pane is the active (focused) pane.
    func setActive(_ active: Bool)

    /// Synchronizes the key-state indicator overlay with the view's current
    /// indicator text.
    func syncKeyStateIndicator(text: String?)

    /// Draws or clears the mobile-viewport cap border.
    ///
    /// - Parameters:
    ///   - size: The capped content size in points, or nil to clear.
    ///   - drawRight: Whether the cap shrinks the width (right border).
    ///   - drawBottom: Whether the cap shrinks the height (bottom border).
    func setMobileViewportBorder(size: CGSize?, drawRight: Bool, drawBottom: Bool)
}
