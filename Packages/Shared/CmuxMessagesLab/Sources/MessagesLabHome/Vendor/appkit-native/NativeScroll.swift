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
    }

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
    func place(_ value: Double, proportion: CGFloat) {
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
    override func trackKnob(with event: NSEvent) {
        // Track the knob ourselves: the value is a fraction of the history.
        var e: NSEvent? = event
        let slot = rect(for: .knobSlot)
        let knob = rect(for: .knob)
        let grab = convert(event.locationInWindow, from: nil).y - knob.minY
        while let ev = e, ev.type != .leftMouseUp {
            let y = convert(ev.locationInWindow, from: nil).y - grab
            let v = Double(max(0, min(1, (y - slot.minY) / max(1, slot.height - knob.height))))
            fixed = (v, knobProportion)
            super.doubleValue = v
            onJump(v)
            e = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp])
        }
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
