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

    /// Where cmux draws the side panel header over Chromium's (this view's
    /// coordinates), nil without an open side panel. A hole like
    /// `occlusionRects`, kept apart so the owner's rects never drop it.
    public var sidePanelHeaderRect: CGRect? {
        didSet {
            guard sidePanelHeaderRect != oldValue else { return }
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

    /// A tab switch removes the host from one container and adds it to another.
    /// The frame can be identical in both containers, so frame setters alone do
    /// not tell Chromium that its coordinate space changed.
    public override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        postGeometryChange()
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
    /// on every geometry update, so window rects convert at the current
    /// position.
    @objc public func cmuxOcclusionRects() -> NSArray {
        allOcclusionRects.map { NSValue(rect: $0) } as NSArray
    }

    /// The panel's holes, the separator row and the window's holes
    /// (``CEFWindowOcclusion``: the command palette, a divider band under the
    /// pointer) in this view's coordinates, as non-overlapping rects: the fork
    /// masks with even-odd rules, so an overlap would show the page again.
    var allOcclusionRects: [CGRect] {
        var rects = occlusionRects
        if let sidePanelHeaderRect { rects.append(sidePanelHeaderRect) }
        if let separator = Self.chromiumSeparatorRect(in: bounds) { rects.append(separator) }
        if let window, let registry = CEFWindowOcclusion.existing(for: window) {
            rects += registry.rectsInWindow.map { convert($0, from: nil) }
        }
        let shown = rects.map { $0.intersection(bounds) }.filter { !$0.isNull && !$0.isEmpty }
        return Self.disjointUnion(Self.outermost(shown))
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

    /// Read by the fork (`-cmuxClipPath`) on every geometry update: the
    /// owner's clip, or else the window's rounded corners where the page
    /// reaches them, so no square page corner shows past the window's.
    @objc public func cmuxClipPath() -> NSBezierPath? {
        guard let shape = clipPath ?? windowCornerClip else { return nil }
        return NSBezierPath(cgPath: shape)
    }

    /// The window's rounded frame intersected with this view, nil when the
    /// view reaches no window corner (or the window has square corners).
    var windowCornerClip: CGPath? {
        guard let window else { return nil }
        let windowRect = convert(CGRect(origin: .zero, size: window.frame.size), from: nil)
        return Self.cornerClip(bounds: bounds, windowRect: windowRect, radius: Self.cornerRadius(of: window))
    }

    /// `bounds` cut to `windowRect` rounded by `radius`, nil when no corner
    /// square of the rounded rect overlaps `bounds`.
    static func cornerClip(bounds: CGRect, windowRect: CGRect, radius: CGFloat) -> CGPath? {
        let radius = min(radius, min(windowRect.width, windowRect.height) / 2)
        guard radius > 0.01, !bounds.isEmpty else { return nil }
        let r = windowRect
        let corners = [
            CGRect(x: r.minX, y: r.minY, width: radius, height: radius),
            CGRect(x: r.maxX - radius, y: r.minY, width: radius, height: radius),
            CGRect(x: r.minX, y: r.maxY - radius, width: radius, height: radius),
            CGRect(x: r.maxX - radius, y: r.maxY - radius, width: radius, height: radius),
        ]
        let reachesCorner = corners.contains { corner in
            let overlap = corner.intersection(bounds)
            return !overlap.isNull && overlap.width > 0.01 && overlap.height > 0.01
        }
        guard reachesCorner else { return nil }
        let rounded = CGPath(roundedRect: windowRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        return CGPath(rect: bounds, transform: nil).intersection(rounded)
    }

    /// The window's corner radius (AppKit's `_cornerRadius`); none in full
    /// screen or for an untitled window.
    static func cornerRadius(of window: NSWindow) -> CGFloat {
        guard window.styleMask.contains(.titled), !window.styleMask.contains(.fullScreen) else { return 0 }
        let selector = NSSelectorFromString("_cornerRadius")
        guard window.responds(to: selector), let value = window.value(forKey: "_cornerRadius") as? NSNumber else {
            return 0
        }
        return CGFloat(value.doubleValue)
    }

    /// The union of `rects` as non-overlapping rects: horizontal bands
    /// between every distinct edge, each band's covered x-ranges merged, and
    /// bands with the same ranges joined vertically (as CmuxBrowser's
    /// `BrowserPageOcclusionPlan.disjointUnion`, which this package cannot import).
    static func disjointUnion(_ rects: [CGRect]) -> [CGRect] {
        let rects = rects.filter { !$0.isNull && !$0.isEmpty }
        guard rects.count > 1 else { return rects }
        guard rects.contains(where: { rect in rects.contains { $0 != rect && $0.intersects(rect) } }) else {
            return rects
        }
        let edges = Set(rects.flatMap { [$0.minY, $0.maxY] }).sorted()
        var result: [CGRect] = []
        var open: [ClosedRange<CGFloat>: CGRect] = [:]
        for (top, bottom) in zip(edges, edges.dropFirst()) {
            let spans = rects
                .filter { $0.minY < bottom && $0.maxY > top }
                .map { $0.minX...$0.maxX }
                .sorted { $0.lowerBound < $1.lowerBound }
            var merged: [ClosedRange<CGFloat>] = []
            for span in spans {
                if let last = merged.last, span.lowerBound <= last.upperBound {
                    merged[merged.count - 1] = last.lowerBound...max(last.upperBound, span.upperBound)
                } else {
                    merged.append(span)
                }
            }
            var next: [ClosedRange<CGFloat>: CGRect] = [:]
            for span in merged {
                if let running = open.removeValue(forKey: span), running.maxY == top {
                    next[span] = CGRect(x: running.minX, y: running.minY, width: running.width, height: bottom - running.minY)
                } else {
                    next[span] = CGRect(x: span.lowerBound, y: top, width: span.upperBound - span.lowerBound, height: bottom - top)
                }
            }
            result.append(contentsOf: open.values)
            open = next
        }
        result.append(contentsOf: open.values)
        return result.sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
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

    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let window, window !== newWindow {
            CEFWindowOcclusion.existing(for: window)?.remove(self)
            let center = NotificationCenter.default
            center.removeObserver(self, name: CEFWindowOcclusion.didChangeNotification, object: window)
            for name in Self.windowGeometryNotifications {
                center.removeObserver(self, name: name, object: window)
            }
        }
        super.viewWillMove(toWindow: newWindow)
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            CEFWindowOcclusion.registry(for: window).add(self)
            // Selector observers: NotificationCenter drops them with the view.
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(windowGeometryDidChange(_:)),
                               name: CEFWindowOcclusion.didChangeNotification, object: window)
            for name in Self.windowGeometryNotifications {
                center.addObserver(self, selector: #selector(windowGeometryDidChange(_:)), name: name, object: window)
            }
        }
        onPresentationChange?(self)
    }

    /// Window changes that move the page or change its holes or corner clip
    /// without a frame change of this view (Next `requestPageUpdate`).
    private static let windowGeometryNotifications: [Notification.Name] = [
        NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
        NSWindow.didChangeBackingPropertiesNotification, NSWindow.didChangeScreenNotification,
        NSWindow.didDeminiaturizeNotification, NSWindow.didChangeOcclusionStateNotification,
        NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
    ]

    @objc private func windowGeometryDidChange(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        postGeometryChange()
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
