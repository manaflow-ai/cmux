public import CoreGraphics

/// The set-state seam a terminal pane uses to drive its ring/flash overlay
/// chrome.
///
/// The pane container (and the surface model behind it) only ever pushes
/// `Sendable` state through this protocol. The conforming overlay view owns the
/// AppKit `NSView`/`CAShapeLayer` instances; callers never touch them directly.
/// This is the boundary that lets the overlay chrome live in the terminal
/// surface view package while the pane assembly stays in the app target.
///
/// All members are `@MainActor`: the overlays are AppKit views.
@MainActor
public protocol TerminalPaneChromeHosting: AnyObject {
    /// Configures the static notification-ring stroke/glow presentation.
    ///
    /// Called once at setup (and again if the palette changes). The ring stays
    /// hidden until ``setNotificationRing(visible:)`` shows it.
    func configureNotificationRing(presentation: TerminalPaneRingPresentation)

    /// Seeds the flash overlay's resting presentation.
    ///
    /// Called once at setup so the flash path/appearance are correct on the
    /// first relayout even before any flash has played. ``triggerFlash`` later
    /// overrides this with the flash that is actively playing.
    func configureFlash(presentation: TerminalPaneRingPresentation)

    /// Shows or hides the notification ring.
    func setNotificationRing(visible: Bool)

    /// Plays a one-shot attention flash.
    ///
    /// - Parameters:
    ///   - style: which flash style is playing (records the last style so a
    ///     later relayout can re-derive the path).
    ///   - presentation: the resolved stroke/glow/metrics for this flash.
    ///   - animation: the opacity keyframe animation to run.
    func triggerFlash(
        style: TerminalPaneFlashStyle,
        presentation: TerminalPaneRingPresentation,
        animation: TerminalPaneFlashAnimationSpec
    )

    /// Lays the ring overlays out to fill `bounds` and refreshes their paths.
    ///
    /// Called from the pane's geometry pass. The container reuses the
    /// notification-ring and last-flash presentations it was configured with, so
    /// the paths/appearance stay correct across relayouts without the caller
    /// re-supplying them.
    func layoutPaneChrome(bounds: CGRect)
}
