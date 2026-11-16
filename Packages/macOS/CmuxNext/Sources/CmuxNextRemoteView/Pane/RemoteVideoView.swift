package import AppKit

/// Hosts the presenter's layer at the image rect (1:1 device pixels, padded
/// or clipped, never scaled; `RemoteViewGeometry`) and the remote cursor
/// overlay (`RemoteCursorPresentation`: where the remote cursor differs from
/// the local pointer). Flipped, like stream pixels.
package final class RemoteVideoView: NSView {
    private(set) var presenter: (any RemoteFramePresenter)?
    package private(set) var framePixels: CGSize = .zero
    private let cursorLayer = CALayer()
    private var cursor: RemoteCursorState?
    /// Whether the overlay draws the remote cursor (the pane's presentation decision).
    private(set) var drawsCursorOverlay = false
    /// How the frame maps onto the pane (`.fit` for compatibility sources).
    package var scaling: RemoteViewGeometry.Scaling = .native {
        didSet {
            guard scaling != oldValue else { return }
            applyScaling()
            needsLayout = true
        }
    }

    nonisolated package override var isFlipped: Bool { true }

    package override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        cursorLayer.actions = RemoteLayerActions.none
        cursorLayer.contentsGravity = .resize
        cursorLayer.magnificationFilter = .linear
        cursorLayer.minificationFilter = .trilinear
        cursorLayer.isHidden = true
        cursorLayer.zPosition = 1
        // The shadow the window server draws under every macOS cursor (HIServices cursors/*/info.plist:
        // black at 0.45, blur 2, 1 pt down), in this view's points, as on a worn remote shape.
        // Cursor images carry none. Flipped: positive y falls below.
        cursorLayer.shadowColor = CGColor(gray: 0, alpha: 1)
        cursorLayer.shadowOpacity = 0.45
        cursorLayer.shadowRadius = 1
        cursorLayer.shadowOffset = CGSize(width: 0, height: 1)
        layer?.addSublayer(cursorLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    package func install(_ presenter: any RemoteFramePresenter) {
        self.presenter?.layer.removeFromSuperlayer()
        self.presenter = presenter
        layer?.insertSublayer(presenter.layer, at: 0)
        presenter.setBackingScale(backingScale)
        applyScaling()
        needsLayout = true
    }

    /// A fitted image fills its layer (filtered); a native one is 1:1.
    private func applyScaling() {
        guard let layer = presenter?.layer else { return }
        layer.contentsGravity = scaling == .fit ? .resize : .topLeft
        layer.minificationFilter = scaling == .fit ? .trilinear : .linear
        layer.magnificationFilter = .linear
    }

    package func setFramePixels(_ size: CGSize) {
        framePixels = size
        needsLayout = true
    }

    /// The remote cursor and whether the overlay draws it. Moves the layer at once (a
    /// cursor update must not wait for the next layout pass).
    func setRemoteCursor(_ cursor: RemoteCursorState?, drawsOverlay: Bool) {
        self.cursor = cursor
        drawsCursorOverlay = drawsOverlay
        placeCursor()
    }

    package func setBackground(_ color: NSColor) {
        layer?.backgroundColor = color.cgColor
    }

    package var backingScale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    var geometry: RemoteViewGeometry? {
        guard framePixels.width > 0, framePixels.height > 0 else { return nil }
        return RemoteViewGeometry(framePixels: framePixels, bounds: bounds, backingScale: backingScale, scaling: scaling)
    }

    package override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        presenter?.setBackingScale(backingScale)
        cursorLayer.contentsScale = backingScale
        needsLayout = true
    }

    package override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let geometry {
            presenter?.layer.frame = geometry.imageRect
            presenter?.layer.isHidden = false
        } else {
            presenter?.layer.isHidden = true
        }
        CATransaction.commit()
        placeCursor()
    }

    /// The overlay at the remote position, in the remote shape at the picture's scale
    /// (the system arrow until a shape arrived).
    private func placeCursor() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard drawsCursorOverlay, let geometry, let cursor, cursor.visible,
              geometry.containsStreamPixel(cursor.position.x, cursor.position.y) else {
            cursorLayer.isHidden = true
            return
        }
        let point = geometry.panePoint(forStreamPixel: cursor.position.x, cursor.position.y)
        let frame: CGRect
        if let shape = cursor.shape {
            let scale = geometry.pointsPerStreamPixel
            if cursorLayer.contents as AnyObject? !== shape.image { cursorLayer.contents = shape.image }
            frame = CGRect(x: point.x - shape.hotSpot.x * scale, y: point.y - shape.hotSpot.y * scale,
                           width: shape.pixelSize.width * scale, height: shape.pixelSize.height * scale)
        } else {
            let arrow = NSCursor.arrow
            if cursorLayer.contents as AnyObject? !== arrow.image { cursorLayer.contents = arrow.image }
            frame = CGRect(origin: CGPoint(x: point.x - arrow.hotSpot.x, y: point.y - arrow.hotSpot.y), size: arrow.image.size)
        }
        cursorLayer.frame = frame
        cursorLayer.isHidden = false
    }
}
