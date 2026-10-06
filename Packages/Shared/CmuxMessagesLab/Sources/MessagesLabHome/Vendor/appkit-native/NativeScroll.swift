import AppKit

/// The transcript's scrolling is AppKit's: an NSScrollView owns the events
/// (trackpad phases, momentum, mouse wheel, scroller, keyboard and
/// accessibility scrolling), the elastic edges and responsive scrolling. The
/// shared window view keeps its transcript layer tree (row layers, additive
/// springs in window space, the clip mask); its scroll offset is the clip
/// view's bounds origin, the same bounds-origin mechanism NSClipView uses for
/// its own layer, applied in the same transaction.
///
/// Coordinates: the scroll view fills the window under the titlebar with
/// AppKit's automatic top inset T (so the titlebar's scroll edge effect covers
/// the transcript). Document coordinates are the shared content coordinates;
/// the shared list starts `shift` = 80 pt above the window, so the clip view's
/// bounds origin is `contentOffset + shift`. The document view's frame spans
/// `minOffset + shift + T ... contentHeight`, so AppKit's allowed range
/// (document top minus the inset, document bottom minus the clip height) is
/// exactly the shared `minOffset ... pinnedOffset`, and AppKit's own
/// constraint and elasticity apply at the oldest loaded row and at the pin.
///
/// Scrolling is AppKit's (user decision): nothing here shapes the motion.
///
/// Two directions:
/// - clip view moves (user, momentum, rubber band) -> `collection.contentOffset`
///   and `userScrolled()` (paging, pin state, thumb, morph shift);
/// - the shared code moves the offset (pin on send, rebase on prepend, jumps)
///   -> `collection.delegate` (this bridge) sets the clip view's origin and
///   the document frame before the window view handles the change.
class TranscriptScrollView: NSScrollView, UIScrollViewDelegate {
    let clip = TranscriptClipView()
    let document = TranscriptDocumentView()
    private(set) weak var demo: MessagesWindowView?
    private var applyingClip = false
    /// > 0 while the model drives the clip view (nested: layout, tile, sync).
    private var applyingModel = 0
    private(set) var liveScrolling = false
    /// Counts for the bench (clip-to-model and model-to-clip syncs).
    static var clipSyncs = 0, modelSyncs = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        drawsBackground = false
        backgroundColor = .clear
        borderType = .noBorder
        hasHorizontalScroller = false
        hasVerticalScroller = true
        scrollerStyle = .overlay
        autohidesScrollers = true
        horizontalScrollElasticity = .none
        verticalScrollElasticity = .allowed
        // No automatic titlebar inset: the scroll view starts below the
        // titlebar (no scroll edge effect, user decision R76).
        automaticallyAdjustsContentInsets = false
        contentInsets = NSEdgeInsetsZero
        clip.drawsBackground = false
        clip.postsBoundsChangedNotifications = true
        contentView = clip
        documentView = document
        verticalScroller = SequenceScroller()
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(clipMoved(_:)), name: NSView.boundsDidChangeNotification, object: clip)
        nc.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: self, queue: nil) { [weak self] _ in self?.setLive(true) }
        nc.addObserver(forName: NSScrollView.didEndLiveScrollNotification, object: self, queue: nil) { [weak self] _ in self?.setLive(false) }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The shared window view's transcript list (a layer-only scroll view).
    var collection: UIScrollView? { demo?.collection }

    func attach(_ demo: MessagesWindowView) {
        self.demo = demo
        // The window view stays the list's delegate through this bridge.
        demo.collection.delegate = self
        syncFromModel()
    }

    private func setLive(_ on: Bool) {
        liveScrolling = on
        guard let p = collection?.physics else { return }
        p.isTracking = on
        p.isDragging = on
        p.isDecelerating = on
        if !on { demo?.userScrolled() }
    }

    /// The shared transcript's layer host. It is a subview of the clip view
    /// (behind the document view, not in it), kept on the visible area: the
    /// titlebar's scroll edge effect blurs only what the scroll view itself
    /// renders above its backdrop (measured: with the rows behind the scroll
    /// view the pocket existed but blurred nothing).
    weak var pinnedContent: NSView? {
        didSet {
            guard let v = pinnedContent else { return }
            clip.addSubview(v, positioned: .below, relativeTo: document)
            pinContent()
        }
    }

    /// The pinned content sits on the window's area whatever the clip
    /// origin (same transaction as the clip's bounds change).
    func pinContent() {
        guard let v = pinnedContent, let host = superview else { return }
        let f = CGRect(origin: CGPoint(x: clip.bounds.minX - clip.frame.minX - frame.minX,
                                       y: clip.bounds.minY - clip.frame.minY - frame.minY), size: host.bounds.size)
        guard v.frame != f else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        v.frame = f
        CATransaction.commit()
    }

    /// Overlay scrollers always: the rows span the full window width under
    /// the scroller (a legacy scroller would narrow the clip view and cut the
    /// pinned rows).
    override var scrollerStyle: NSScroller.Style {
        get { .overlay }
        set { super.scrollerStyle = .overlay }
    }

    /// The shared list's top above the scroll view's top (80 pt).
    var shift: CGFloat { -(collection?.frame.minY ?? 0) + frame.minY }

    // MARK: Clip view -> model

    @objc private func clipMoved(_ n: Notification) {
        pinContent()
        guard applyingModel == 0, let demo, let cv = collection else { return }
        let y = clip.bounds.origin.y - shift
        guard y != cv.contentOffset.y else { return }
        TranscriptScrollView.clipSyncs += 1
        applyingClip = true
        CATransaction.begin(); CATransaction.setDisableActions(true)
        cv.contentOffset = CGPoint(x: 0, y: y)
        // The window view handles a scroll as the user's when the list is
        // tracking or decelerating (live scroll); scroller drags, keyboard
        // and accessibility scrolling are the user's too.
        if !liveScrolling { demo.userScrolled() }
        CATransaction.commit()
        applyingClip = false
        // The list rounds to the pixel grid; keep the clip view on it too.
        if cv.contentOffset.y != y { pushOffset() }
        if let sel = document.controller?.selection, !sel.isEmpty { sel.refresh() }
    }

    // MARK: Model -> clip view

    /// UIScrollViewDelegate: the list's offset changed (either direction).
    func scrollViewDidScroll(_ sv: UIScrollView) {
        if !applyingClip { syncFromModel() }
        demo?.scrollViewDidScroll(sv)
    }

    /// Document extent and clip origin from the shared layout. Cheap; called
    /// after every engine action and every model offset change.
    func syncFromModel() {
        guard let demo else { return }
        let top = demo.minOffset + shift + contentInsets.top, contentH = demo.layout.collectionViewContentSize.height
        let f = NSRect(x: 0, y: top, width: bounds.width, height: max(1, contentH - top))
        applyingModel += 1
        if document.frame != f { document.frame = f }
        applyingModel -= 1
        pushOffset()
    }

    private func pushOffset() {
        guard let cv = collection else { return }
        let y = cv.contentOffset.y + shift
        guard clip.bounds.origin.y != y else { return }
        TranscriptScrollView.modelSyncs += 1
        applyingModel += 1
        clip.setBoundsOrigin(NSPoint(x: 0, y: y))
        reflectScrolledClipView(clip)
        pinContent()
        applyingModel -= 1
    }

    // MARK: Scroller

    /// The knob shows the position in the whole history (the loaded window
    /// is a few hundred messages of a million), as the window view's own
    /// thumb does.
    override func reflectScrolledClipView(_ cView: NSClipView) {
        super.reflectScrolledClipView(cView)
        guard let demo, let s = verticalScroller as? SequenceScroller else { return }
        s.place(demo.historyFraction, proportion: demo.historyProportion)
        // The indicator shows only while the person scrolls (wheel, trackpad, keys,
        // knob): Messages shows none at rest, on a pointer move, during live resize or
        // when the app moves the transcript (a send pinning it to the bottom).
        let y = cView.bounds.origin.y
        if y != lastRevealOrigin {
            if applyingModel == 0, !inLiveResize { s.reveal() }
            lastRevealOrigin = y
        }
    }
    private var lastRevealOrigin: CGFloat = .nan

    /// The overlay scroller ends above the field (the top inset is AppKit's).
    func placeScroller(bottom: CGFloat) {
        if scrollerInsets.bottom != bottom { scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: bottom, right: 0) }
    }

    /// Scroll to a shared offset through the clip view (bench, audit, keys).
    func scroll(toModelOffset y: CGFloat) {
        clip.scroll(to: NSPoint(x: 0, y: y + shift))
        reflectScrolledClipView(clip)
    }

    /// AppKit changed the automatic insets (titlebar, accessory): the
    /// document's top follows.
    private var tiling = false
    /// Layout sets the automatic insets (titlebar adjacency), which scrolls
    /// the clip view: the model offset wins there too.
    override func layout() {
        applyingModel += 1
        super.layout()
        applyingModel -= 1
        if !tiling { tiling = true; syncFromModel(); tiling = false }
    }

    override func tile() {
        // AppKit keeps the visible content in place when the automatic inset
        // changes (it moves the clip view); the shared model's offset (pinned
        // or anchored) wins instead.
        applyingModel += 1
        super.tile()
        applyingModel -= 1
        guard !tiling else { return }
        tiling = true
        syncFromModel()
        tiling = false
    }
}

/// The scroll trace's scroll view. With responsive scrolling AppKit reads a
/// trackpad gesture from the window server's stream on its own thread, so
/// events a probe posts into the app's queue never move it (measured: wheel
/// clicks scroll, phased trackpad events do not). Overriding `scrollWheel(_:)`
/// opts a scroll view out of responsive scrolling: AppKit then applies the
/// posted stream (phases, momentum, elasticity) on the main thread. Used only
/// with `--scroll-trace`; the app keeps responsive scrolling.
final class TraceableTranscriptScrollView: TranscriptScrollView {
    override func scrollWheel(with event: NSEvent) { super.scrollWheel(with: event) }
}

/// Flipped clip view (the transcript's content coordinates are y-down).
final class TranscriptClipView: NSClipView {
    override var isFlipped: Bool { true }
}

/// The scroll view's document: no drawing, no layers of its own (the rows are
/// the shared layer tree's). It forwards clicks, menus and drops to the
/// controller in window-content coordinates.
final class TranscriptDocumentView: NSView {
    weak var controller: ChatController?
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {}
    /// First responder only while it holds a text selection (Copy); a click
    /// leaves the compose field focused.
    override var acceptsFirstResponder: Bool { controller.map { $0.selection.dragging || !$0.selection.isEmpty } ?? false }
    private func hostPoint(_ e: NSEvent) -> CGPoint { controller?.host.convert(e.locationInWindow, from: nil) ?? .zero }
    override func mouseDown(with event: NSEvent) { controller?.mouseDown(at: hostPoint(event), event) }
    override func mouseDragged(with event: NSEvent) { controller?.mouseDragged(at: hostPoint(event), event) }
    override func mouseUp(with event: NSEvent) { controller?.mouseUp(at: hostPoint(event), event) }
    override func menu(for event: NSEvent) -> NSMenu? { controller?.menu(at: hostPoint(event)) }
}

/// The overlay scroller over a paged history: knob position and length come
/// from the window view (message sequence over the history), not from the
/// loaded document's extent. Dragging the knob jumps to that place in history.
final class SequenceScroller: NSScroller {
    private var fixed: (value: Double, proportion: CGFloat)?
    var onJump: (Double) -> Void = { _ in }
    /// A track click with "click in the scroll bar: jump to the next page" (+1 down, -1 up).
    var onPage: (Int) -> Void = { _ in }
    /// While the person drags the knob it stays under the pointer: model updates
    /// (estimates resolving, pages loading) wait and apply on release.
    private(set) var dragging = false
    private var pendingModel: (Double, CGFloat)?
    func place(_ value: Double, proportion: CGFloat) {
        if dragging { pendingModel = (value, proportion); return }
        fixed = (value, proportion)
        if doubleValue != value { super.doubleValue = value }
        if knobProportion != proportion { super.knobProportion = proportion }
    }
    override var doubleValue: Double {
        get { super.doubleValue }
        set { super.doubleValue = fixed?.value ?? newValue }
    }
    override var knobProportion: CGFloat {
        get { super.knobProportion }
        set { super.knobProportion = fixed?.proportion ?? newValue }
    }
    /// Messages' scroll indicator (macOS 27, lossless still): a 7 pt bar of grey 87 with a
    /// 0.5 pt dark (27) edge, its right side 2 pt from the window's right edge, no track.
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}
    /// Own visibility: AppKit's overlay fade does not reach an overridden `drawKnob`, so
    /// the knob stayed drawn at rest. Shown on `reveal()` (every user scroll movement), faded
    /// out after a pause. Timing fitted to Messages (scrollbar-scroll-fade reference, thumb
    /// level per frame): fade-in 0.24 s, cubic-bezier (0.3, 1, 0.6, 1) (rms 0.005), starting
    /// 0.054 s after the wheel event (ours' first movement comes about that late, so no extra
    /// delay); fade-out starts 0.72 s after the last wheel event and is linear, 0.092 s.
    /// Messages animates a wheel step 0.09 s longer than ours; scroll pacing is out of the
    /// parity bar, so the hold counts from ours' last movement (about the event time).
    private var shown = false
    private var hideTimer: Timer?, showTimer: Timer?
    static let showDelay: TimeInterval = 0, fadeInTime: TimeInterval = 0.24
    static let holdTime: TimeInterval = 0.72, fadeTime: TimeInterval = 0.092
    func reveal() {
        hideTimer?.invalidate()
        if !shown {
            shown = true
            alphaValue = 0
            needsDisplay = true
            showTimer?.invalidate()
            showTimer = Timer.scheduledTimer(withTimeInterval: Self.showDelay, repeats: false) { [weak self] _ in
                guard let self, self.shown else { return }
                NSAnimationContext.runAnimationGroup { c in
                    c.duration = Self.fadeInTime
                    c.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 1, 0.6, 1)
                    self.animator().alphaValue = 1
                }
            }
        } else if showTimer?.isValid != true, alphaValue < 1 {
            // Scrolling again during the fade-out: back to full at once.
            alphaValue = 1
        }
        hideTimer = Timer.scheduledTimer(withTimeInterval: Self.holdTime, repeats: false) { [weak self] _ in
            guard let self, !self.dragging else { return }
            NSAnimationContext.runAnimationGroup({ c in
                c.duration = Self.fadeTime
                c.timingFunction = CAMediaTimingFunction(name: .linear)
                self.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self, self.alphaValue == 0 else { return }
                self.shown = false
                self.needsDisplay = true
            })
        }
    }
    /// The drawn bar (scroller coordinates): 7 pt wide at the window's right edge
    /// minus 2 pt, top and bottom on whole device pixels at every position (no
    /// row of the edge lost or doubled while it moves).
    var barRect: NSRect {
        guard let win = window else { return .zero }
        let k = rect(for: .knob)
        // cmux: 2 pt from the scroller's own right edge: in a Home pane the window's
        // right edge is not the transcript's (the same place when the pane is the window).
        let right = bounds.maxX - 2
        let s = win.backingScaleFactor
        let top = (k.minY * s).rounded() / s, h = max(1, (k.height * s).rounded() / s)
        return NSRect(x: right - 7, y: top, width: 7, height: h)
    }
    override func drawKnob() {
        guard shown else { return }
        let bar = barRect
        NSColor(white: 27 / 255, alpha: 1).setFill()
        NSBezierPath(roundedRect: bar.insetBy(dx: -0.5, dy: -0.5), xRadius: 4, yRadius: 4).fill()
        NSColor(white: 87 / 255, alpha: 1).setFill()
        NSBezierPath(roundedRect: bar, xRadius: 3.5, yRadius: 3.5).fill()
    }

    // MARK: Pointer

    /// Knob or track. On the knob: drag. In the track: the system's "Click in the
    /// scroll bar" setting (AppleScrollerPagingBehavior): jump to the spot (then
    /// drag from the knob's middle), or page toward the click.
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let knob = rect(for: .knob)
        if knob.insetBy(dx: -4, dy: 0).contains(p) || !rect(for: .knobSlot).contains(p) && knob.minY <= p.y && p.y <= knob.maxY {
            track(event, grab: p.y - knob.minY); return
        }
        let jump = UserDefaults.standard.bool(forKey: "AppleScrollerPagingBehavior") != event.modifierFlags.contains(.option)
        if jump {
            dragBegan(at: p.y, grab: knob.height / 2)
            dragMoved(to: p.y)
            track(nil, grab: knob.height / 2)
        } else {
            reveal()
            onPage(p.y > knob.midY ? 1 : -1)
        }
    }
    override func trackKnob(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        track(event, grab: p.y - rect(for: .knob).minY)
    }
    private func track(_ first: NSEvent?, grab: CGFloat) {
        if let first { dragBegan(at: convert(first.locationInWindow, from: nil).y, grab: grab) }
        while let ev = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if ev.type == .leftMouseUp { break }
            dragMoved(to: convert(ev.locationInWindow, from: nil).y)
        }
        dragEnded()
    }

    // Drag steps (also driven directly by the self-test).
    private var grab: CGFloat = 0
    private var dragProportion: CGFloat = 0
    func dragBegan(at y: CGFloat, grab g: CGFloat) {
        dragging = true; grab = g; dragProportion = knobProportion
        reveal()
    }
    /// The knob's top goes to the pointer minus the grab offset (clamped at the ends);
    /// its size stays as it was when the drag began.
    func dragMoved(to y: CGFloat) {
        let slot = rect(for: .knobSlot)
        let kh = rect(for: .knob).height
        let v = Double(max(0, min(1, (y - grab - slot.minY) / max(1, slot.height - kh))))
        fixed = (v, dragProportion)
        super.doubleValue = v
        onJump(v)
    }
    func dragEnded() {
        dragging = false
        if let (v, prop) = pendingModel { pendingModel = nil; place(v, proportion: prop) }
        reveal()
    }
}

/// The shim's `UIScrollView.physics`: in this app only the tracking flags,
/// set by the NSScrollView during a live scroll (AppKit does the physics).
final class ScrollPhysics {
    unowned let view: UIScrollView
    var isTracking = false
    var isDragging = false
    var isDecelerating = false
    init(_ v: UIScrollView) { view = v }
}
