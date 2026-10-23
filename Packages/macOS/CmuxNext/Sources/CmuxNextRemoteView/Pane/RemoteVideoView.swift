package import AppKit

/// Hosts the presenter's layer at the image rect (1:1 device pixels, padded
/// or clipped, never scaled; `RemoteViewGeometry`) and the remote cursor
/// overlay for view mode. Flipped, like stream pixels.
package final class RemoteVideoView: NSView {
    private(set) var presenter: (any RemoteFramePresenter)?
    package private(set) var framePixels: CGSize = .zero
    private let cursorLayer = CALayer()
    private var cursor: RemoteCursorState?
    /// Draws the remote cursor (view mode only; control mode shows the local one).
    var showsRemoteCursor = false {
        didSet { if showsRemoteCursor != oldValue { needsLayout = true } }
    }
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
        cursorLayer.contentsGravity = .topLeft
        cursorLayer.contents = NSCursor.arrow.image
        cursorLayer.isHidden = true
        cursorLayer.zPosition = 1
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

    func setRemoteCursor(_ cursor: RemoteCursorState?) {
        self.cursor = cursor
        needsLayout = true
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
        if let geometry, showsRemoteCursor, let cursor, cursor.visible {
            let image = NSCursor.arrow
            let hotSpot = image.hotSpot
            let point = geometry.panePoint(forStreamPixel: cursor.position.x, cursor.position.y)
            cursorLayer.frame = CGRect(origin: CGPoint(x: point.x - hotSpot.x, y: point.y - hotSpot.y), size: image.image.size)
            cursorLayer.isHidden = false
        } else {
            cursorLayer.isHidden = true
        }
        CATransaction.commit()
    }
}
