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
/// clip reads them without a key-value lookup (crash ratchet). The mask leaves them out of the
/// layer content as well (`place(_:cutouts:scale:)`): a pane growing over a corner of this one (a zoom)
/// has transparent padding, and this pane must not show through it.
public nonisolated final class StripClipMaskLayer: CALayer {
    public private(set) var cutouts: [CGRect] = []
    /// The mask with holes: the frame less the cutouts. Nil without cutouts, when the plain opaque
    /// background is the mask.
    private var holes: CAShapeLayer?

    public override init() { super.init() }

    public override init(layer: Any) {
        super.init(layer: layer)
        cutouts = (layer as? StripClipMaskLayer)?.cutouts ?? []
    }

    public required init?(coder: NSCoder) { super.init(coder: coder) }

    /// Shows the masked layer inside `frame` less `cutouts` (both in the masked layer's
    /// coordinates), as a Chromium page's clip shape does (`CEFClipShape.path`: the union of the
    /// cutouts subtracted), rendered at `scale`. The caller disables implicit actions.
    public func place(_ frame: CGRect, cutouts: [CGRect], scale: CGFloat) {
        self.frame = frame
        self.cutouts = cutouts
        let holes = cutouts.map { $0.offsetBy(dx: -frame.minX, dy: -frame.minY).intersection(bounds) }
            .filter { !$0.isNull && $0.width > 0.01 && $0.height > 0.01 }
        guard !holes.isEmpty else {
            self.holes?.removeFromSuperlayer()
            self.holes = nil
            backgroundColor = CGColor(gray: 0, alpha: 1)
            return
        }
        let shape = self.holes ?? {
            let shape = CAShapeLayer()
            shape.fillColor = CGColor(gray: 0, alpha: 1)
            addSublayer(shape)
            self.holes = shape
            return shape
        }()
        backgroundColor = nil
        (shape.frame, shape.contentsScale) = (bounds, scale)
        var path = CGPath(rect: bounds, transform: nil)
        for hole in holes { path = path.subtracting(CGPath(rect: hole, transform: nil)) }
        shape.path = path
    }
}
