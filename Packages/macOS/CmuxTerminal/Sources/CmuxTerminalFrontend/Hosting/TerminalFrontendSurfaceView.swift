public import AppKit

/// Ghostty-free visual host for one externally rendered terminal surface.
///
/// Renderer pixels are mounted as a child view. Pointer and keyboard events
/// pass through to the app's interaction adapter until that adapter is also
/// moved into this frontend product.
@MainActor
public final class TerminalFrontendSurfaceView: NSView {
    /// Creates an empty frontend surface with a plain Core Animation layer.
    ///
    /// - Parameter frameRect: The initial surface bounds in points.
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    @available(*, unavailable, message: "Construct frontend surfaces in code")
    required init?(coder: NSCoder) {
        nil
    }

    /// Frontend pixels never become the event target while the compatibility
    /// interaction adapter owns input, IME, drag-and-drop, and accessibility.
    public override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    /// Creates a non-Metal backing layer for the compositor mount.
    ///
    /// The child compositor owns the only host-process Metal layer and submits
    /// one IOSurface blit per admitted frame.
    public override func makeBackingLayer() -> CALayer {
        let backingLayer = CALayer()
        backingLayer.isOpaque = false
        return backingLayer
    }
}
