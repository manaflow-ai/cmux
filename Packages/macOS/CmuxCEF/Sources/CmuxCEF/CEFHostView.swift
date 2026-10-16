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

    /// The Chromium fork tracks this view with a separate child window. AppKit
    /// does not otherwise send the fork's geometry notification when a tab's
    /// host is reparented or resized, so keep the child window's frame in sync
    /// with the view that owns it.
    public override func setFrameSize(_ newSize: NSSize) {
        let changed = frame.size != newSize
        super.setFrameSize(newSize)
        if changed { postGeometryChange() }
    }

    /// Notifies the Chromium child window when the host moves within its pane.
    public override func setFrameOrigin(_ newOrigin: NSPoint) {
        let changed = frame.origin != newOrigin
        super.setFrameOrigin(newOrigin)
        if changed { postGeometryChange() }
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
        var rects = occlusionRects
        if let separator = Self.chromiumSeparatorRect(in: bounds) { rects.append(separator) }
        return Self.outermost(rects.map { $0.intersection(bounds) }.filter { !$0.isNull && !$0.isEmpty })
            .map { NSValue(rect: $0) } as NSArray
    }

    /// Chromium's window draws a 1 pt contents separator above the web
    /// contents (the page is 1 pt shorter than its window), which showed as
    /// a light line under cmux's toolbar where WebKit has none. A hole over
    /// that row hides it; what shows instead is the pane behind this view.
    static let chromiumSeparatorHeight: CGFloat = 1

    /// The top row of `bounds` (this view is not flipped), nil when too small.
    static func chromiumSeparatorRect(in bounds: CGRect) -> CGRect? {
        guard bounds.height > chromiumSeparatorHeight * 2, bounds.width > 0 else { return nil }
        return CGRect(x: bounds.minX, y: bounds.maxY - chromiumSeparatorHeight,
                      width: bounds.width, height: chromiumSeparatorHeight)
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
