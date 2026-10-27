import AppKit
import CmuxNextDesign
import QuartzCore

/// Spike p04-input-102 (input-pipeline-DESIGN.md I4, "Spike 102"): the column strip, or one column's rows,
/// in an `NSScrollView` that AppKit can scroll on its own thread while the main thread is busy (responsive
/// scrolling), set against p03-rendering-026's main-thread container translation. Chrome's model is the
/// compositor thread scrolling the layer tree with no main-thread turn per update
/// (`cc/input/threaded_input_handler.cc`); AppKit's matching path keeps a scroll view on that thread only
/// while its classes are compatible (`+isCompatibleWithResponsiveScrolling`) and none of them overrides
/// `scrollWheel(_:)`, so nothing here does: input reaches the host through AppKit's own tracking.
///
/// The column scroll rules stay in ``ColumnScrollState``: the host feeds it the clip's offsets as a gesture
/// and lands on the reducer's snap target at the end with a render-server spring of the document layer's
/// translation from where the strip shows. Each clip move comes from the clip's own geometry hooks
/// (``StripScrollClipView``, no bounds notification); the start and the end of AppKit's live scroll (momentum
/// included) come from the owner (``liveScrollBegan()``, ``liveScrollEnded()``), which forwards them from the
/// window's one live-scroll adapter. The design doc records why the app keeps p03-026's path (the decision); the host
/// is not placed in a window by the app.
final class StripScrollHost: NSScrollView {
    override class var isCompatibleWithResponsiveScrolling: Bool { true }

    /// A landing on the render server: the document shows `displacement` (points along the axis, the view's
    /// space) away from the clip and springs to rest from `begin`.
    struct Landing {
        var displacement: CGFloat
        var begin: CFTimeInterval
        var spring: SpringParameters
        var serial: Int
    }

    /// The strip's scroll axis: x for the column strip, y for a column's rows (``RowScroll`` transposes
    /// them into a strip whose offsets run down).
    let axis: SplitAxis
    let document: StripScrollDocumentView
    /// The column scroll rules, fed by live scrolling and model syncs (``show(_:focused:source:)``).
    private(set) var scrollState = ColumnScrollState()
    /// The landing in flight, if any.
    private(set) var landing: Landing?
    /// Called with the pane a gesture's end moved focus to (``ColumnScrollEffects/focus``).
    var onFocus: (PaneID) -> Void = { _ in }
    /// The clip offset at the last live-scroll update; nil outside a live scroll.
    private var liveOffset: CGFloat?
    private var landingSerial = 0
    private let landingSpring: RenderSpring
    /// The event timebase the reducer's gesture samples read (`NSEvent.timestamp`'s, system uptime).
    private let now: () -> TimeInterval
    /// The render server's timebase the landing record reads.
    private let mediaNow: () -> CFTimeInterval

    /// `landingSpring` is the gated scroll spring (`Motion.panes.renderSpring(.scroll)`).
    init(frame frameRect: NSRect, axis: SplitAxis, landingSpring: RenderSpring,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         mediaNow: @escaping () -> CFTimeInterval = { CACurrentMediaTime() }) {
        self.axis = axis
        self.landingSpring = landingSpring
        self.now = now
        self.mediaNow = mediaNow
        document = StripScrollDocumentView(frame: NSRect(origin: .zero, size: frameRect.size), axis: axis)
        super.init(frame: frameRect)
        wantsLayer = true
        drawsBackground = false
        borderType = .noBorder
        hasHorizontalScroller = false
        hasVerticalScroller = false
        usesPredominantAxisScrolling = true
        horizontalScrollElasticity = axis == .horizontal ? .allowed : .none
        verticalScrollElasticity = axis == .vertical ? .allowed : .none
        let clip = StripScrollClipView(frame: NSRect(origin: .zero, size: frameRect.size))
        contentView = clip
        documentView = document
        tile()
        clip.onOriginChange = { [weak self] in self?.liveScrolled() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The clip's offset along the axis: the content-space leading edge of the viewport.
    var offset: CGFloat {
        axis == .horizontal ? contentView.bounds.origin.x : contentView.bounds.origin.y
    }

    /// Whether AppKit is tracking a live scroll (finger down or momentum).
    var isLiveScrolling: Bool { liveOffset != nil }

    // MARK: Model

    /// Takes a model snapshot: sizes the document to the strip and syncs the reducer (camera anchor,
    /// restore, reveal). Outside a live scroll the clip follows at once: the anchor's shift in this frame,
    /// the reveal as a landing. During one the clip is AppKit's; the gesture's end lands on the target.
    func show(_ strip: ColumnStrip, focused: PaneID?, source: ColumnFocusSource) {
        takeLandingWhereItShows()
        document.setFrameSize(documentSize(for: strip))
        scrollState.reduce(.sync(strip, focused: focused, source: source, animated: true))
        guard liveOffset == nil else { return }
        land()
    }

    // MARK: Live scroll

    /// AppKit began tracking a scroll: a landing in flight stops where it shows and the gesture starts there.
    func liveScrollBegan() {
        takeLandingWhereItShows()
        scrollState.spring.value = offset
        scrollState.reduce(.gestureBegan)
        liveOffset = offset
    }

    /// The clip moved (under responsive scrolling AppKit syncs it on the main thread's next turn): during a
    /// live scroll, one gesture sample. The host moves the clip itself only outside live scrolls.
    func liveScrolled() {
        guard let last = liveOffset else { return }
        let current = offset
        guard current != last else { return }
        scrollState.reduce(.gestureChanged(deltaX: last - current, time: now()))
        liveOffset = current
    }

    /// AppKit's live scroll ended, momentum included, so the clip is at rest: the reducer picks the snap
    /// nearest the rest offset and the focus there (``ColumnScrollEvent/gestureRested(animated:)``), and the
    /// host lands there. The samples' deltas are the main thread's view of AppKit's moves (one large
    /// catch-up after a stall), not a release velocity: AppKit's momentum already coasted. Returns the
    /// target, or nil when no live scroll was tracked.
    @discardableResult
    func liveScrollEnded() -> CGFloat? {
        guard liveOffset != nil else { return nil }
        liveScrolled()
        liveOffset = nil
        let effects = scrollState.reduce(.gestureRested(animated: true))
        let target = scrollState.spring.target
        land()
        if let focus = effects.focus { onFocus(focus) }
        return target
    }

    // MARK: Landing

    /// Moves the clip to the reducer's target in this frame and shows the strip where the camera was
    /// (``ColumnScrollState`` `spring.value`), springing the document's translation to rest on the render
    /// server. Shows at rest at once when the gate does not animate.
    private func land() {
        let shown = scrollState.spring.value
        let target = scrollState.spring.target
        scrollState.spring.snap()
        moveClip(to: target)
        let displacement = target - shown
        let key = document.translationKey
        guard abs(displacement) > 0.25, let layer = document.layer, landingSpring.animates(key.path, in: document) else { return }
        landingSerial += 1
        let serial = landingSerial
        let sign = document.layerAxisSign
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        key.set(displacement * sign, on: layer)
        CATransaction.commit()
        landing = Landing(displacement: displacement, begin: mediaNow(), spring: landingSpring.parameters, serial: serial)
        landingSpring.animate(layer, key, to: CGFloat(0), velocity: 0, in: document) { [weak self] finished in
            guard let self, finished, self.landing?.serial == serial else { return }
            self.landing = nil
        }
    }

    /// Ends a landing where it shows: the clip moves there and the translation goes, so nothing moves on
    /// screen; the reducer's camera value is what shows, its target stays.
    private func takeLandingWhereItShows() {
        guard let landing, let layer = document.layer else { return }
        let solved = SpringValue.solve(displacement: Double(landing.displacement), velocity: 0,
                                       time: mediaNow() - landing.begin, parameters: landing.spring)
        self.landing = nil
        let key = document.translationKey
        RenderSpring.stop(layer, key.path)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        key.set(0, on: layer)
        CATransaction.commit()
        moveClip(to: offset - CGFloat(solved.displacement))
        scrollState.spring.value = offset
    }

    private func moveClip(to value: CGFloat) {
        let origin = contentView.bounds.origin
        contentView.scroll(to: axis == .horizontal ? NSPoint(x: value, y: origin.y) : NSPoint(x: origin.x, y: value))
        reflectScrolledClipView(contentView)
    }

    private func documentSize(for strip: ColumnStrip) -> NSSize {
        let viewport = contentView.bounds.size
        let length = max(strip.contentWidth, strip.viewportWidth)
        return axis == .horizontal ? NSSize(width: length, height: viewport.height) : NSSize(width: viewport.width, height: length)
    }
}

/// The clip of ``StripScrollHost``: draws nothing, so AppKit may scroll it on its own thread. It tells the
/// host of each origin change from its own geometry hooks, whichever AppKit path moves it
/// (`ScrollGeometryClipView`'s pattern).
final class StripScrollClipView: NSClipView {
    override class var isCompatibleWithResponsiveScrolling: Bool { true }

    var onOriginChange: () -> Void = {}
    private var toldOrigin: NSPoint = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        drawsBackground = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func setBoundsOrigin(_ newOrigin: NSPoint) {
        super.setBoundsOrigin(newOrigin)
        originMayHaveChanged()
    }

    override func scroll(to newOrigin: NSPoint) {
        super.scroll(to: newOrigin)
        originMayHaveChanged()
    }

    override var bounds: NSRect {
        didSet { originMayHaveChanged() }
    }

    private func originMayHaveChanged() {
        let origin = bounds.origin
        guard origin != toldOrigin else { return }
        toldOrigin = origin
        onOriginChange()
    }
}

/// The document of ``StripScrollHost``: the strip's pane hosts in content space. It draws nothing itself
/// (its subviews' layers are the content), and it asks AppKit to keep the strip's keep-alive band prepared,
/// one viewport past each end of the visible rect along the axis (`ScreenContentView.recordVisibilitySpan`'s
/// band), so a scroll on AppKit's thread has content to show while the main thread cannot draw.
final class StripScrollDocumentView: NSView {
    override class var isCompatibleWithResponsiveScrolling: Bool { true }

    let axis: SplitAxis

    init(frame frameRect: NSRect, axis: SplitAxis) {
        self.axis = axis
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        autoresizesSubviews = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    nonisolated override var isFlipped: Bool { true }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {}

    override func prepareContent(in rect: NSRect) {
        let visible = enclosingScrollView?.documentVisibleRect ?? rect
        super.prepareContent(in: Self.keepAliveBand(around: visible, prepared: rect, bounds: bounds, axis: axis))
    }

    /// `prepared` (AppKit's overdraw choice) widened to one viewport past each end of `visible` along
    /// `axis`, within `bounds`.
    nonisolated static func keepAliveBand(around visible: NSRect, prepared: NSRect, bounds: NSRect, axis: SplitAxis) -> NSRect {
        let band = axis == .horizontal ? visible.insetBy(dx: -visible.width, dy: 0) : visible.insetBy(dx: 0, dy: -visible.height)
        return prepared.union(band).intersection(bounds)
    }

    /// The layer key path a landing springs: the sublayer translation along the axis.
    var translationKey: RenderSpringKey<CGFloat> { axis == .horizontal ? .sublayerTranslationX : .sublayerTranslationY }

    /// The sign of the axis in this view's layer (a flipped view's y runs the other way in its layer).
    var layerAxisSign: CGFloat {
        let axes = RenderLayerAxes(self)
        return axis == .horizontal ? axes.x : axes.y
    }
}
