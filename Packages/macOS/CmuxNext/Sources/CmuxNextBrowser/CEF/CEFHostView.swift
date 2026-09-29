import AppKit

/// The parent view of a pane's Chromium window. The fork's
/// `CmuxParentViewTracker` keeps the page window over this view, clips it to
/// the visible rect, and punches holes where `cmuxOcclusionRects` says native
/// UI must show above the page (glass overlays, find bar, prompt bar).
final class CEFHostView: NSView {
    /// Rects in this view's coordinates where native UI covers the page.
    var occlusionRects: [CGRect] = [] {
        didSet {
            guard occlusionRects != oldValue else { return }
            postGeometryChange()
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Read by the fork (`-cmuxOcclusionRects`, NSArray of NSValue NSRect).
    @objc func cmuxOcclusionRects() -> NSArray {
        occlusionRects.map { NSValue(rect: $0) } as NSArray
    }

    /// Tells the tracker about moves AppKit does not report (layer
    /// transforms, manual frame animation in an ancestor).
    func postGeometryChange() {
        NotificationCenter.default.post(name: CEFHostView.geometryDidChange, object: self)
    }

    /// `CmuxParentViewGeometryDidChange` in the fork.
    static let geometryDidChange = Notification.Name("CmuxParentViewGeometryDidChange")
}

/// A CEF tab's `contentView`. All tabs of a pane share one Chromium window,
/// so the container only borrows the pane's `CEFHostView` while it is in a
/// window, and shows a snapshot while the tab is occluded.
final class CEFTabContentView: NSView {
    weak var tab: CEFTab?
    private let snapshotView = NSImageView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        snapshotView.imageScaling = .scaleAxesIndependently
        snapshotView.autoresizingMask = [.width, .height]
        snapshotView.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // Not flipped, like CEFHostView, so occlusion rects in this view's
    // coordinates are also valid in the host view that fills it.

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let tab else { return }
        if window != nil {
            tab.contentDidAppear(in: self)
        } else {
            tab.contentDidDisappear()
        }
    }

    override func layout() {
        super.layout()
        for subview in subviews { subview.frame = bounds }
    }

    /// Shows `image` over the page area (nil removes it).
    func showSnapshot(_ image: CGImage?) {
        if let image {
            snapshotView.image = NSImage(cgImage: image, size: bounds.size)
            snapshotView.frame = bounds
            if snapshotView.superview == nil { addSubview(snapshotView) }
            snapshotView.isHidden = false
        } else {
            snapshotView.isHidden = true
            snapshotView.image = nil
        }
    }
}
