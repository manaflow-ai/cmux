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
            if applyingModel == 0, !inLiveResize, !Self.isElasticSettle(cView) { s.reveal() }
            lastRevealOrigin = y
        }
    }
    /// An origin change in the elastic overshoot past either end that no finger or momentum
    /// phase drives: AppKit's rubber band for a line wheel at the end, or its settle back.
    /// Messages (UIKit) does not overshoot on a line wheel, so it neither shows the scroller
    /// for a wheel toward an end it is already at (scrollbar-hover +9.6 s) nor restarts the
    /// hold while the transcript settles (scrollbar-scroll-fade +3.9 s: its hold counts from
    /// the last move inside the range). The rubber band itself stays (native scrolling).
    private static func isElasticSettle(_ clip: NSClipView) -> Bool {
        let b = clip.bounds, d = clip.documentRect, i = clip.contentInsets
        guard b.minY < d.minY - i.top - 0.5 || b.maxY > d.maxY + i.bottom + 0.5 else { return false }
        if let e = NSApp.currentEvent, e.type == .scrollWheel,
           e.phase == .began || e.phase == .changed || e.momentumPhase == .began || e.momentumPhase == .changed { return false }
        return true
    }
    private var lastRevealOrigin: CGFloat = .nan

    /// The scroller's track spans window y `top` to `bottom` (points from the window's top):
    /// Messages' track runs from under the header (80) to the field's top edge
    /// (scrollbar-hover reference: 80 - 998.5 at a field top of 999). The insets are
    /// corrected by the measured slot (AppKit adds its own inset at each end).
    func placeScroller(top: CGFloat, bottom: CGFloat) {
        guard let s = verticalScroller, let host = superview, s.window != nil else { return }
        let slot = host.convert(s.convert(s.rect(for: .knobSlot), to: nil), from: nil)
        let flipped = host.isFlipped
        let slotTop = flipped ? slot.minY : host.bounds.height - slot.maxY
        let slotBottom = flipped ? slot.maxY : host.bounds.height - slot.minY
        let dt = slotTop - top, db = bottom - slotBottom
        guard abs(dt) > 0.01 || abs(db) > 0.01 else { return }
        var i = scrollerInsets
        i.top -= dt
        i.bottom -= db
        scrollerInsets = i
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
    override var acceptsFirstResponder: Bool { takesFocus || (controller.map { $0.selection.dragging || !$0.selection.isEmpty } ?? false) }
    /// Set around a click in the transcript: Messages takes the focus from the field then.
    var takesFocus = false
    /// Typing while the transcript has the focus goes to the field.
    override func keyDown(with event: NSEvent) {
        guard let c = controller, let chars = event.characters, !chars.isEmpty,
              event.modifierFlags.intersection([.command, .control]).isEmpty,
              chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { super.keyDown(with: event); return }
        c.focusCompose()
        window?.firstResponder?.keyDown(with: event)
    }
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
    /// AppKit invalidates its own knob rect when the value changes; the drawn bar sits up to
    /// `knobBottomInset` (plus pixel rounding) above it and spans the expanded width, so every
    /// invalidation covers the scroller's full width and 2 pt more at each end. (Without it a
    /// slow knob drag left the bar's old top rows in the track: horizontal streaks above the
    /// thumb in ours-scrollbar-drag-slow-take84, the row's transcript excess 4.7.)
    override func setNeedsDisplay(_ invalidRect: NSRect) {
        guard !invalidRect.isEmpty else { return super.setNeedsDisplay(invalidRect) }
        super.setNeedsDisplay(NSRect(x: bounds.minX, y: invalidRect.minY - 2, width: bounds.width, height: invalidRect.height + 4))
    }
    /// Messages' scroll indicator, macOS 27 (lossless scrollbar-* references, right 20 pt strip):
    /// - at rest with overlay scrollers (Show scroll bars: Automatic with a trackpad, or When
    ///   scrolling): hidden; with legacy scrollers (Always, or Automatic with a mouse): shown.
    /// - scrolling: a 7 pt thumb (window x 619-626), white at 0.502 (143 over the background 30),
    ///   a 0.5 pt black edge at 0.2 (24), capsule ends on whole device pixels; no track.
    /// - pointer in the scroller strip while the thumb shows: at once an 11 pt thumb (615-626,
    ///   the same white, 156 over the track) and a full-height track, white at 0.1156 (56 over
    ///   30; the window's edge column 53 -> 76 under it), from x 612 to the window edge, with a
    ///   faint left rim (70, 61 at 612 and 612.5).
    /// - fades: wheel reveal 0.24 s cubic-bezier (0.3, 1, 0.6, 1); after the last wheel event
    ///   0.72 s, then 0.092 s linear; after the pointer leaves the strip 0.80 s, then 0.22 s
    ///   cubic-bezier (0.294, 0.493, 0.389, 0.946) (scrollbar-hover, rms 0.003).
    /// - a press while hidden goes to the transcript (scrollbar-hidden-press).
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        guard shown, expanded, window != nil else { return }
        let right = barRight
        let slot = rect(for: .knobSlot)
        let track = NSRect(x: right - 14, y: slot.minY, width: bounds.maxX - (right - 14), height: slot.height)
        NSColor(white: 1, alpha: 0.1156).setFill()
        track.fill()
        NSColor(white: 1, alpha: 0.07).setFill()
        NSRect(x: track.minX, y: track.minY, width: 0.5, height: track.height).fill(using: .sourceOver)
        NSColor(white: 1, alpha: 0.025).setFill()
        NSRect(x: track.minX + 0.5, y: track.minY, width: 0.5, height: track.height).fill(using: .sourceOver)
    }
    private(set) var shown = false
    /// Pointer in the scroller strip while the thumb shows (wide thumb and track).
    private(set) var expanded = false
    private var pointerInside = false
    private var hideTimer: Timer?, showTimer: Timer?
    static let showDelay: TimeInterval = 0, fadeInTime: TimeInterval = 0.24
    /// Our own delay from a main-thread timer firing to the first changed frame on screen (the
    /// timer's run-loop turn, the commit, one render frame): 2 frames at 120 Hz, measured on the
    /// lossless strip takes. Only the widening (drawn on main) still uses a timer; the fades are
    /// render-server animations that begin at the input's time plus the hold (scheduleHide).
    static let timerToScreen: TimeInterval = 2.0 / 120
    /// Time since the input event was made (its timestamp), so a hold counts from the input,
    /// not from when the event reached this view (0 without an event; at most 0.1 s).
    static func sinceInput(_ e: NSEvent?) -> TimeInterval {
        guard let e, e.timestamp > 0 else { return 0 }
        return min(0.1, max(0, ProcessInfo.processInfo.systemUptime - e.timestamp))
    }
    /// Messages' visual holds (lossless strips): 0.72 s after the last wheel event, 0.78 s
    /// after the pointer leaves the strip, 0.53 s after a drag's release outside it.
    static let holdTime: TimeInterval = 0.72, fadeTime: TimeInterval = 0.092
    /// The leave hold counts from the pointer's exit from the strip (scrollbar-hover: exit at
    /// +7.1425 s, fade from +7.917-7.925 s: 0.775-0.783 s; 0.80 was measured from the 'leave' mark).
    static let leaveHold: TimeInterval = 0.78, leaveFade: TimeInterval = 0.22
    static let dragReleaseHold: TimeInterval = 0.53
    /// Legacy scrollers (the system setting): always shown, never faded.
    var legacy: Bool { NSScroller.preferredScrollerStyle == .legacy }
    private var styleObserver: NSObjectProtocol?
    private var wheelMonitor: Any?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil, let m = wheelMonitor { NSEvent.removeMonitor(m); wheelMonitor = nil }
        if window != nil, wheelMonitor == nil {
            // A local monitor sees each wheel event without opting the scroll view out of
            // responsive scrolling (a scrollWheel(_:) override would).
            wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
                self?.wheelSeen(e)
                return e
            }
        }
        if styleObserver == nil {
            styleObserver = NotificationCenter.default.addObserver(forName: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.applyStyle()
            }
        }
        applyStyle()
    }
    private func applyStyle() {
        cancelHide(); showTimer?.invalidate()
        if legacy { shown = true; alphaValue = 1 } else if !dragging && !pointerInside { shown = false; expanded = false; alphaValue = 0 }
        needsDisplay = true
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // The strip only (no wake-ups for pointer moves elsewhere in the window).
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    /// Messages widens the thumb 0.075 s after the pointer enters the strip (four lossless
    /// takes: 0.074-0.083 s from the entry to the first wide frame), less our timer-to-screen delay.
    static let expandDelay: TimeInterval = 0.075 - timerToScreen
    private var expandTimer: Timer?
    override func mouseEntered(with event: NSEvent) {
        pointerInside = true
        guard shown else { return }
        cancelHide()
        if !legacy, alphaValue < 1, showTimer?.isValid != true { alphaValue = 1 }
        guard !expanded else { return }
        expandTimer?.invalidate()
        expandTimer = Timer.scheduledTimer(withTimeInterval: Self.expandDelay, repeats: false) { [weak self] _ in
            guard let self, self.pointerInside || self.dragging, self.shown else { return }
            self.expanded = true
            self.needsDisplay = true
        }
    }
    override func mouseExited(with event: NSEvent) {
        pointerInside = false
        if !expanded { expandTimer?.invalidate() }
        guard shown, !dragging else { return }
        scheduleHide(after: Self.leaveHold - Self.sinceInput(event), fade: Self.leaveFade, curve: CAMediaTimingFunction(controlPoints: 0.294, 0.493, 0.389, 0.946))
    }
    /// A press where nothing shows goes to the transcript under it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        shown ? super.hitTest(point) : nil
    }
    func reveal() {
        if legacy { return }
        cancelHide()
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
        // The pointer resting in the strip keeps it (it fades after leaving).
        guard !pointerInside else { return }
        let e = NSApp.currentEvent.flatMap { $0.type == .scrollWheel ? $0 : nil }
        scheduleHide(after: Self.holdTime - Self.sinceInput(e), fade: Self.fadeTime, curve: CAMediaTimingFunction(name: .linear))
    }
    /// Every wheel event over the transcript restarts a pending hold, also one that moves
    /// nothing (at an end): Messages holds 0.72 s from its LAST wheel event though its
    /// transcript stopped 0.14 s before it (scrollbar-scroll-fade, mark back). A wheel that
    /// moves nothing does not show a hidden scroller (scrollbar-hover +9.6 s).
    private func wheelSeen(_ e: NSEvent) {
        guard hideTimer?.isValid == true, !pointerInside, !dragging, !legacy, e.window === window,
              let sv = superview as? NSScrollView, sv.bounds.contains(sv.convert(e.locationInWindow, from: nil)) else { return }
        scheduleHide(after: Self.holdTime - Self.sinceInput(e), fade: Self.fadeTime, curve: CAMediaTimingFunction(name: .linear))
    }
    private static let hideKey = "messageslab.scroller.hide"
    /// Stops a pending or running fade: the model alpha is still 1, so the thumb is full again.
    private func cancelHide() {
        hideTimer?.invalidate()
        layer?.removeAnimation(forKey: Self.hideKey)
    }
    /// The fade is a render-server animation that begins `hold` from now (the callers pass the
    /// hold less the input event's age), so it starts on the frame Messages' does, with no
    /// run-loop or commit delay and no main-thread frames (a main-thread fade repeated frames).
    /// A timer at its end sets the model state.
    private func scheduleHide(after hold: TimeInterval, fade: TimeInterval, curve: CAMediaTimingFunction) {
        cancelHide()
        guard !dragging, !pointerInside, !legacy else { return }
        if let layer {
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 1; a.toValue = 0
            a.beginTime = layer.convertTime(CACurrentMediaTime() + max(0, hold), from: nil)
            a.duration = fade
            a.timingFunction = curve
            a.fillMode = .forwards
            a.isRemovedOnCompletion = false
            layer.add(a, forKey: Self.hideKey)
        }
        hideTimer = Timer.scheduledTimer(withTimeInterval: max(0, hold) + fade, repeats: false) { [weak self] _ in
            guard let self, !self.dragging, !self.pointerInside, !self.legacy else { self?.cancelHide(); return }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            self.alphaValue = 0
            self.layer?.removeAnimation(forKey: Self.hideKey)
            CATransaction.commit()
            self.shown = false
            self.expanded = false
            self.needsDisplay = true
        }
    }
    /// The thumb's right edge (scroller coordinates): the window's right edge minus 2 pt.
    /// cmux: the scroller's own right edge: in a Home pane the window's right edge is not
    /// the transcript's (the same place when the pane is the window).
    private var barRight: CGFloat { bounds.maxX - 2 }
    /// The drawn bar (scroller coordinates): 7 pt (11 pt expanded) wide, right edge at the
    /// window's right edge minus 2 pt, top and bottom on whole device pixels at every
    /// position (no row of the edge lost or doubled while it moves).
    /// Messages' thumb stops 1.5 pt above its track's end at the bottom (65 pt thumb at 932-997,
    /// track to 998.5: scrollbar-drag-* and -hover at rest) and reaches the track's top; AppKit's
    /// knob ends at the slot's end. The drawn bar travels over the slot less this inset.
    static let knobBottomInset: CGFloat = 1.5
    var barRect: NSRect {
        guard let win = window else { return .zero }
        let k = rect(for: .knob), slot = rect(for: .knobSlot)
        let s = win.backingScaleFactor
        let travel = slot.height - k.height
        let y = travel > 0 ? slot.minY + (k.minY - slot.minY) * (travel - Self.knobBottomInset) / travel : k.minY
        let top = (y * s).rounded() / s, h = max(1, (k.height * s).rounded() / s)
        let w: CGFloat = expanded ? 11 : 7
        return NSRect(x: barRight - w, y: top, width: w, height: h)
    }
    override func drawKnob() {
        guard shown else { return }
        let bar = barRect
        let r = bar.width / 2
        NSColor(white: 0, alpha: 0.2).setFill()
        let edge = NSBezierPath(roundedRect: bar.insetBy(dx: -0.5, dy: -0.5), xRadius: r + 0.5, yRadius: r + 0.5)
        edge.append(NSBezierPath(roundedRect: bar, xRadius: r, yRadius: r).reversed)
        edge.fill()
        NSColor(white: 1, alpha: 0.5022).setFill()
        NSBezierPath(roundedRect: bar, xRadius: r, yRadius: r).fill()
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
    /// The knob drag began (true) or ended (false).
    var onDrag: (Bool) -> Void = { _ in }
    func dragBegan(at y: CGFloat, grab g: CGFloat) {
        dragging = true; grab = g; dragProportion = knobProportion
        onDrag(true)
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
        onDrag(false)
        if let (v, prop) = pendingModel { pendingModel = nil; place(v, proportion: prop) }
        // The drag's event loop takes the pointer's exit: read where it is now.
        if let w = window { pointerInside = bounds.contains(convert(w.mouseLocationOutsideOfEventStream, from: nil)) }
        reveal()
        if !pointerInside && expanded {
            // Released outside the strip: Messages holds 0.53 s after the release, then
            // the same 0.22 s fade (scrollbar-drag-fast and -slow, both ended below the track).
            scheduleHide(after: Self.dragReleaseHold - Self.sinceInput(NSApp.currentEvent), fade: Self.leaveFade, curve: CAMediaTimingFunction(controlPoints: 0.294, 0.493, 0.389, 0.946))
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
