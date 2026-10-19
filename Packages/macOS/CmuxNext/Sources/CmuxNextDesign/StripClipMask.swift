public import AppKit

public extension CALayer {
    /// The name of the layer mask the column strip puts on a pane that
    /// scrolled under a docked column or past the strip's edge
    /// (`PaneHostView.setStripClip`). A Chromium page is a child window that
    /// no layer mask reaches, so its clip shape reads this one by name
    /// (`CEFClipShape.clips(around:)`), not any other mask on an ancestor.
    static let cmuxStripClipName = "cmux.stripClip"
}

/// That mask's layer: it carries the rects (the masked view's coordinates) a pane in front covers
/// inside the mask's frame, which a Chromium page leaves out of its clip shape too. Typed, so the
/// clip reads them without a key-value lookup (crash ratchet).
public nonisolated final class StripClipMaskLayer: CALayer {
    public var cutouts: [CGRect] = []

    public override init() { super.init() }

    public override init(layer: Any) {
        super.init(layer: layer)
        cutouts = (layer as? StripClipMaskLayer)?.cutouts ?? []
    }

    public required init?(coder: NSCoder) { super.init(coder: coder) }
}
