public import AppKit

/// AppKit container and geometry reference used when installing window overlays.
public struct WindowContentOverlayInstallationTarget {
    /// Container that should receive the overlay view.
    public let container: NSView

    /// Geometry reference: a sibling of the overlay, or the container itself.
    public let reference: NSView

    /// Creates an overlay installation target.
    public init(container: NSView, reference: NSView) {
        self.container = container
        self.reference = reference
    }
}
