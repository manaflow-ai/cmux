public import AppKit

public extension CALayer {
    /// The name of the layer mask the layout puts on a pane partly scrolled out
    /// of its scroll area's window, or held to the strip's range while a zoom
    /// lifts the strip's container (`PaneHostView.setStripClip`; at rest the
    /// strip's clip beside docked columns is its container's bounds, not a mask).
    /// A Chromium page is a child window that
    /// no layer mask reaches, so its clip shape reads this one by name
    /// (`CEFClipShape.clips(around:)`), not any other mask on an ancestor.
    static let cmuxStripClipName = "cmux.stripClip"
}

/// A view that knows what stacks in front of it: a layout pane host, whose page in a child window
/// (`ChildWindowPageFallback`) leaves those parts out of its clip shape, since no view order reaches a
/// window above the cmux window. Views ordered in the window's layer tree need none of it.
@MainActor
public protocol PageCoverSource: NSView {
    /// The rects (this view's coordinates) the views stacked in front of it cover. Asked only when a
    /// child-window page reads its clip, never on a motion frame; a read with nothing changed since
    /// the last one should cost no walk.
    func pageCovers() -> [CGRect]
}

/// A view whose content can draw in its own child window above the cmux window (a Chromium page,
/// `ChildWindowPageFallback`). No layer animation reaches that window: it follows the views' model
/// frames, so the layout keeps motion that changes what stacks over it on the main thread's frames
/// (`ScreenContentView.springZoomOnRenderServer`).
@MainActor
public protocol ChildWindowContent: NSView {
    /// True while the content draws in its own child window, not in the window's layer tree.
    var drawsInChildWindow: Bool { get }
}

/// That mask's layer: an opaque rect. A pane in front is ordered above it in the layer tree, so the
/// mask carries no holes for it; a page in a child window leaves those parts out of its own clip
/// shape (`PageCoverSource`, `ChildWindowPageFallback`).
public nonisolated final class StripClipMaskLayer: CALayer {
    public override init() { super.init() }

    public override init(layer: Any) { super.init(layer: layer) }

    public required init?(coder: NSCoder) { super.init(coder: coder) }

    /// Shows the masked layer inside `frame` (the masked layer's coordinates). The caller disables
    /// implicit actions.
    public func place(_ frame: CGRect) {
        self.frame = frame
        if backgroundColor == nil { backgroundColor = CGColor(gray: 0, alpha: 1) }
    }
}
