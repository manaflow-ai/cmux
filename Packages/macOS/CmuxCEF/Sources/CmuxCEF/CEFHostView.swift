public import AppKit

/// The parent view of a browser's Chromium window. The fork's
/// `CmuxParentViewTracker` keeps the page window over this view, clips it to
/// the visible rect, punches holes where `occlusionRects` says native UI must
/// show above the page (find bar, notices, popovers) and masks it to
/// `clipPath` (rounded pane corners).
///
/// The page is a child window, not a subview: anything that must draw over
/// the page has to be a hole here or a window above it.
@MainActor
public final class CEFHostView: NSView {
    /// Rects in this view's coordinates where native UI covers the page.
    public var occlusionRects: [CGRect] = [] {
        didSet {
            guard occlusionRects != oldValue else { return }
            postGeometryChange()
        }
    }

    /// A clip for the page in this view's coordinates (rounded corners), or
    /// nil for the plain rect.
    public var clipPath: CGPath? {
        didSet { postGeometryChange() }
    }

    /// Called when the view enters or leaves a window, or is hidden or shown.
    var onPresentationChange: (@MainActor (CEFHostView) -> Void)?
    /// The color the view shows until the page's first frame (the theme
    /// background, set by the owner).
    public var placeholderColor: NSColor = .windowBackgroundColor {
        didSet { updateBackground() }
    }
    /// False once the page painted: the view is then transparent, so no
    /// placeholder band can show around the page window where its frame
    /// rounds differently from this view's (design spec §0.4).
    public var showsPlaceholder = true {
        didSet { if showsPlaceholder != oldValue { updateBackground() } }
    }

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        updateBackground()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
    }

    private func updateBackground() {
        guard showsPlaceholder else {
            layer?.backgroundColor = nil
            return
        }
        var color = placeholderColor.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            color = placeholderColor.cgColor
        }
        layer?.backgroundColor = color
    }

    /// Read by the fork (`-cmuxOcclusionRects`, NSArray of NSValue NSRect)
    /// on every geometry update.
    @objc public func cmuxOcclusionRects() -> NSArray {
        Self.outermost(occlusionRects.map { $0.intersection(bounds) }.filter { !$0.isNull && !$0.isEmpty })
            .map { NSValue(rect: $0) } as NSArray
    }

    /// Read by the fork (`-cmuxClipPath`) on every geometry update.
    @objc public func cmuxClipPath() -> NSBezierPath? {
        guard let clipPath else { return nil }
        return NSBezierPath(cgPath: clipPath)
    }

    /// `rects` without those inside another (one of equal rects stays): a
    /// hole inside a hole would cancel it in an even-odd mask.
    static func outermost(_ rects: [CGRect]) -> [CGRect] {
        rects.enumerated().filter { index, rect in
            !rects.enumerated().contains { other, outer in
                other != index && outer.contains(rect) && (outer != rect || other < index)
            }
        }.map(\.element)
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onPresentationChange?(self)
    }

    public override func viewDidHide() {
        super.viewDidHide()
        onPresentationChange?(self)
    }

    public override func viewDidUnhide() {
        super.viewDidUnhide()
        onPresentationChange?(self)
    }

    /// True when the page should show: in a window and not hidden.
    var isPresented: Bool { window != nil && !isHiddenOrHasHiddenAncestor }

    /// Tells the tracker about moves AppKit does not report (layer
    /// transforms, manual frame animation in an ancestor).
    public func postGeometryChange() {
        NotificationCenter.default.post(name: CEFHostView.geometryDidChange, object: self)
    }

    /// `CmuxParentViewGeometryDidChange` in the fork.
    public static let geometryDidChange = Notification.Name("CmuxParentViewGeometryDidChange")
}
