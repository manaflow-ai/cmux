import AppKit
import CmuxNextDesign

/// A WebKit tab's `contentView`: the parent of the `WKWebView`, owned by
/// the tab. The chrome pins this container with Auto Layout; the web view
/// inside uses only autoresizing.
///
/// WebKit's attached Web Inspector (WebInspectorUIProxyMac) adds its view to
/// the web view's superview and sets the web view's frame to the area left,
/// and applies that again whenever the web view's frame changes. It must be
/// the only owner of the web view's frame while attached: when the chrome
/// pinned the web view itself, every layout pass reset it to full size and
/// WebKit shrank it back, so the inspector flickered on every frame. This
/// container never sets the web view's frame after adding it while the
/// inspector is attached; a container resize reaches it once through
/// autoresizing, and WebKit re-places both. Device emulation places the web
/// view itself only while it is alone in the container.
final class WebKitPageContainer: NSView, PaneMotionHolding {
    /// The web view; WebKit owns its frame (an attached inspector shrinks it).
    private(set) weak var page: NSView?

    /// What hides the web view from WebKit (``WebKitPageVisibility``): the web view's own `isHidden`, set in the
    /// change's turn, so a show is applied before the switch's frame commits. Only the web view: an attached
    /// inspector or a stand-in beside it keeps its own state.
    var visibility: WebKitPageVisibility {
        didSet { if visibility.hidesPage != oldValue.hidesPage { page?.isHidden = visibility.hidesPage } }
    }

    init(page: NSView, visibility: WebKitPageVisibility = WebKitPageVisibility()) {
        self.page = page
        self.visibility = visibility
        super.init(frame: .zero)
        page.isHidden = visibility.hidesPage
        // Layer-backed for the gutter beside a held page (`WebKitPageContainer+SpringResize`).
        wantsLayer = true
        page.frame = bounds
        page.autoresizingMask = [.width, .height]
        page.translatesAutoresizingMaskIntoConstraints = true
        addSubview(page)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    nonisolated override var isFlipped: Bool { false }

    /// WebKit added or removed a view beside the page (the attached Web
    /// Inspector shows and hides this way).
    var onSubviewsChange: (() -> Void)?

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        // An attached Web Inspector owns the web view's frame from now on: no spring holds it.
        if subview !== page { endSpringHold() }
        onSubviewsChange?()
        if emulation != nil { needsLayout = true }
    }

    override func willRemoveSubview(_ subview: NSView) {
        super.willRemoveSubview(subview)
        onSubviewsChange?()
        if emulation != nil { needsLayout = true }
    }

    // MARK: Device emulation (WebKitTab+DeviceEmulation)

    /// The tab's emulation, nil for none. For a device the web view gets
    /// exactly the device's CSS size, centered at the top, and the container
    /// scales its bounds when the device is bigger than the pane (Chrome's
    /// fit), so the page's viewport stays the device's. For a fit the web
    /// view gets the desktop layout size for the fit area and the container
    /// scales it to fill that area (centered when the pane is wider), with a
    /// `BrowserFitFrameView` around it (backdrop, bounds, bar). While an attached Web Inspector
    /// shares the container, WebKit owns the web view's frame: the container
    /// then keeps unscaled bounds and autoresizing and leaves the frame alone
    /// (only the user agent and scale factor apply); when the inspector goes,
    /// the device size returns.
    var emulation: BrowserEmulation? {
        didSet {
            guard emulation != oldValue else { return }
            // The emulation owns the web view's frame from now on: no spring holds it.
            endSpringHold()
            placeEmulatedPage()
        }
    }

    override func layout() {
        super.layout()
        placeEmulatedPage()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if emulation != nil { placeEmulatedPage() }
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        if springHold == nil { joinSpringResize() }
        if let springHold, let page {
            // Held at its top-left: the container's resize moves it, and WebKit lays out nothing.
            let held = springHold.rect(in: bounds, flipped: isFlipped)
            if page.frame != held { page.frame = held }
            return
        }
        guard emulation != nil, pageAlone else { return super.resizeSubviews(withOldSize: oldSize) }
        placeEmulatedPage()
    }

    /// The size its pane's spring rests at, held at the top-left until it lands (`WebKitPageContainer+SpringResize`).
    var springHold: SpringPageHold?
    /// `PaneMotionHolding`: the web view is held at its pane's rest size.
    var holdsPaneMotionSize: Bool { springHold != nil }
    /// The pane host it sits in when that pane's pages hold their size in springs (the `pageSpringResizeOnce`
    /// feature), found once each time it moves (`placeInPane()`); nil otherwise, so a resize without the
    /// feature walks no ancestors.
    weak var springPlacement: (any RestingPlacement)?
    /// The document's own background, for the gap beside a held page (`WebKitTab+SpringBackdrop`); nil for a
    /// see-through page (blank, the New Tab page, a document that has not painted) and before it is read.
    var pageBackdrop: CGColor? {
        didSet { if springHold != nil, pageBackdrop != oldValue { layer?.backgroundColor = pageBackdrop } }
    }
    /// Asks the tab to read ``pageBackdrop`` (`WebKitTab.samplePageBackdrop`): the container joined a pane
    /// whose pages hold their size in springs.
    var needsPageBackdrop: (() -> Void)?

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        placeInPane()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        placeInPane()
    }

    private var isScaledForEmulation = false
    /// A fit's backdrop, bounds hairline and bar (below the page), nil otherwise.
    private var fitFrame: BrowserFitFrameView?

    /// The web view is alone in the container (no attached Web Inspector beside it).
    var pageAlone: Bool { subviews.allSatisfy { $0 === page || $0 === fitFrame } }

    private func placeEmulatedPage() {
        guard let page else { return }
        updateFitFrame()
        fitFrame?.isHidden = !pageAlone
        guard let placement = emulatedPlacement(), pageAlone else {
            // No emulation, or the inspector owns the web view's frame.
            guard isScaledForEmulation else { return }
            isScaledForEmulation = false
            setBoundsSize(frame.size)
            setBoundsOrigin(.zero)
            page.autoresizingMask = [.width, .height]
            if pageAlone { page.frame = bounds }
            return
        }
        isScaledForEmulation = true
        let (target, scale) = placement
        let scaled = CGSize(width: frame.width / scale, height: frame.height / scale)
        if bounds.size != scaled { setBoundsSize(scaled) }
        if bounds.origin != .zero { setBoundsOrigin(.zero) }
        page.autoresizingMask = []
        if page.frame != target { page.frame = target }
        if let fitFrame {
            // Drawn at 1:1 points whatever the container's scale.
            let whole = CGRect(origin: .zero, size: scaled)
            if fitFrame.frame != whole { fitFrame.frame = whole }
            if fitFrame.bounds.size != frame.size { fitFrame.setBoundsSize(frame.size) }
            let presented = CGRect(x: target.minX * scale, y: target.minY * scale, width: target.width * scale, height: target.height * scale)
            fitFrame.update(emulation: emulation, presented: presented, layout: target.size, scale: scale)
        }
    }

    /// Adds the fit frame for a fit (below the page) and removes it otherwise.
    private func updateFitFrame() {
        if emulation?.fit != nil, fitFrame == nil {
            let view = BrowserFitFrameView()
            fitFrame = view
            addSubview(view, positioned: .below, relativeTo: page)
        } else if emulation?.fit == nil, let view = fitFrame {
            fitFrame = nil
            view.removeFromSuperview()
        }
    }

    /// The web view's frame (in the container's scaled bounds) and the
    /// container's scale for the emulation in the current frame, nil to show
    /// the page as is. A device sits centered at the top; a fit sits where
    /// `BrowserEmulation.presentedRect` puts it, inside the fit frame's margins.
    private func emulatedPlacement() -> (CGRect, CGFloat)? {
        guard let emulation, frame.width > 0, frame.height > 0 else { return nil }
        let whole = CGRect(origin: .zero, size: frame.size)
        if emulation.fit != nil {
            guard let viewport = emulation.viewport(in: emulation.layoutArea(in: whole).size),
                  let presented = emulation.presentedRect(in: whole) else { return nil }
            let scale = viewport.scale
            return (CGRect(x: presented.minX / scale, y: presented.minY / scale, width: viewport.size.width, height: viewport.size.height), scale)
        }
        guard emulation.width > 0, emulation.height > 0 else { return nil }
        let size = CGSize(width: emulation.width, height: emulation.height)
        let scale = min(1, frame.width / size.width, frame.height / size.height)
        let scaled = CGSize(width: frame.width / scale, height: frame.height / scale)
        // Not flipped: the top edge is maxY.
        return (CGRect(x: ((scaled.width - size.width) / 2).rounded(.down), y: scaled.height - size.height, width: size.width, height: size.height), scale)
    }
}
