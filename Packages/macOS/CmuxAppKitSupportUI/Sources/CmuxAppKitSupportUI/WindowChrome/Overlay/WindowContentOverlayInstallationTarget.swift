public import AppKit

/// AppKit container/reference pair used when installing overlays above window content.
public struct WindowContentOverlayInstallationTarget {
    /// Container that should receive the overlay view.
    public let container: NSView

    /// Sibling reference view used to position the overlay in the AppKit hierarchy.
    public let reference: NSView

    /// Creates an overlay installation target.
    public init(container: NSView, reference: NSView) {
        self.container = container
        self.reference = reference
    }
}
