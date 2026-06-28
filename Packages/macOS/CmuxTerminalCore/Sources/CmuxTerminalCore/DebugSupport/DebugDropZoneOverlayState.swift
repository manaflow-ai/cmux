public import CoreGraphics

/// A snapshot of a terminal surface's drop-zone overlay view, read by the debug
/// socket and the drop regression tests to verify the overlay is hidden and
/// correctly attached.
///
/// The live `NSView` reads (`isHidden`, `frame`, superview identity) stay
/// app-side on the main actor;
/// `GhosttySurfaceScrollView.debugDropZoneOverlayState()` captures them into
/// this pure value.
public struct DebugDropZoneOverlayState {
    /// Whether the overlay view is hidden.
    public let isHidden: Bool
    /// The overlay view's frame in its superview's coordinate space.
    public let frame: CGRect
    /// Whether the overlay is a subview of the hosted terminal view.
    public let isAttachedToHostedView: Bool
    /// Whether the overlay is a subview of the parent container.
    public let isAttachedToParentContainer: Bool

    /// Captures a drop-zone overlay snapshot from already-read view state.
    public init(
        isHidden: Bool,
        frame: CGRect,
        isAttachedToHostedView: Bool,
        isAttachedToParentContainer: Bool
    ) {
        self.isHidden = isHidden
        self.frame = frame
        self.isAttachedToHostedView = isAttachedToHostedView
        self.isAttachedToParentContainer = isAttachedToParentContainer
    }
}
