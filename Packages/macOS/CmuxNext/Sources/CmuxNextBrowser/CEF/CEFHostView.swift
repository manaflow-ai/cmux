import AppKit
import CmuxNextDesign

/// The parent view of a pane's Chromium window. The fork's
/// `CmuxParentViewTracker` keeps the page window over this view, clips it to
/// the visible rect, and punches holes where `cmuxOcclusionRects` says native
/// UI must show above the page (find bar, prompt bar) or must get the mouse
/// (the window's dividers and switcher, `BrowserWindowOcclusionProviding`),
/// and masks it to `cmuxClipPath` (rounded pane and window corners).
final class CEFHostView: NSView {
    /// Rects in this view's coordinates where native UI covers the page.
    var occlusionRects: [CGRect] = [] {
        didSet {
            guard occlusionRects != oldValue else { return }
            postGeometryChange()
        }
    }
    private var windowObserver: (any NSObjectProtocol)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        updateBackground()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
    }

    /// Until Chromium's page window shows its first frame, the page area is
    /// the theme color, never white (`PageBackground`).
    private func updateBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Palette.pageBackground.cgColor
        }
    }

    isolated deinit {
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
    }

    /// Read by the fork (`-cmuxOcclusionRects`, NSArray of NSValue NSRect)
    /// on every geometry update, so window rects convert at the current
    /// position.
    @objc func cmuxOcclusionRects() -> NSArray {
        allOcclusionRects.map { NSValue(rect: $0) } as NSArray
    }

    /// Read by the fork (`-cmuxClipPath`) on every geometry update: the
    /// pane's rounded clip and the window's rounded corners, so no square
    /// page corner shows past either. Nil when the page is a plain rect.
    @objc func cmuxClipPath() -> NSBezierPath? {
        CEFClipShape.path(bounds: bounds, clips: CEFClipShape.clips(around: self)).map { NSBezierPath(cgPath: $0) }
    }

    /// The chrome's rects plus the window's interactive overlays over this
    /// view, in this view's coordinates.
    var allOcclusionRects: [CGRect] {
        var rects = occlusionRects
        if let provider = window as? any BrowserWindowOcclusionProviding {
            for rect in provider.browserOcclusionRectsInWindow {
                let local = convert(rect, from: nil).intersection(bounds)
                if !local.isNull, !local.isEmpty { rects.append(local) }
            }
        }
        return rects
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
        windowObserver = nil
        guard let window else { return }
        windowObserver = NotificationCenter.default.addObserver(forName: BrowserChildWindowPages.needsUpdate, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.postGeometryChange() }
        }
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
        layoutContent()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        layoutContent()
    }

    /// The page (the pane's shared `CEFHostView` and the snapshot) takes
    /// the page frame; a docked DevTools and its divider take the rest.
    func layoutContent() {
        let frames = tab?.devToolsFrames(in: bounds)
            ?? CEFDevToolsLayout.Frames(page: bounds, devTools: .zero, line: .zero, grab: .zero)
        let devToolsHost = tab?.devToolsViews?.host
        for subview in subviews {
            let frame: CGRect
            if subview === devToolsHost {
                frame = frames.devTools
            } else if subview is CEFDevToolsDivider {
                frame = frames.grab
            } else {
                frame = frames.page
            }
            if subview.frame != frame { subview.frame = frame }
        }
        tab?.applyOcclusion()
    }

    /// Shows `image` over the page area (nil removes it).
    func showSnapshot(_ image: CGImage?) {
        if let image {
            let page = tab?.devToolsFrames(in: bounds).page ?? bounds
            snapshotView.image = NSImage(cgImage: image, size: page.size)
            snapshotView.frame = page
            if snapshotView.superview == nil { addSubview(snapshotView) }
            snapshotView.isHidden = false
        } else {
            snapshotView.isHidden = true
            snapshotView.image = nil
        }
    }
}
