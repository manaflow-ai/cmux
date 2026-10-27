import AppKit
import CmuxNextDesign
import CmuxNextInput
import CmuxNextWakeups
import QuartzCore

/// The thin scrollbar under the column strip (dock-column.md, B1 to B5):
/// a neutral thumb showing the visible range, no track color. Dragging the
/// thumb scrolls, a click beside it pages. `system` (the default) follows
/// ``SystemScrollers/nativeStyle``: `auto`, as every scroller in cmux is thin and
/// shown only while scrolling (SCROLLBARS-THIN). `auto` fades it in while the
/// strip scrolls or the pointer is over it and out after a one-shot
/// deadline; `always` keeps it while columns overflow; `off` hides it.
/// It takes the mouse only while shown, so clicks pass to the panes below.
/// While shown, its thumb is an occluder of the window's overlay host, so a
/// Chromium page under it (a child window above every view) leaves the thumb
/// showing and its clicks to the bar (cx-6so.44).
final class StripScrollbarView: NSView {
    struct Input: Equatable {
        var mode: StripScrollbarMode
        /// The track in this view's superview, full hit band height.
        var band: CGRect
        var offset: CGFloat
        var contentWidth: CGFloat
        var viewportWidth: CGFloat
        var snaps: [CGFloat]
    }

    /// Thumb drag lifecycle and track clicks, in strip offsets. Drag times are the events' own
    /// (`NSEvent.timestamp`, seconds since boot), so the release velocity reads when the pointer moved.
    var onDragBegan: (() -> Void)?
    /// The thumb passed `offset` at `time` before a later point of the same frame delivery: it counts
    /// toward the release velocity, and the strip does not show it.
    var onDragSample: ((_ offset: CGFloat, _ time: TimeInterval) -> Void)?
    /// The strip shows `offset`, where the pointer was at `time`.
    var onDrag: ((_ offset: CGFloat, _ time: TimeInterval) -> Void)?
    var onDragEnded: ((_ time: TimeInterval) -> Void)?
    var onPage: ((CGFloat) -> Void)?
    /// The windows' frame-aligned pointer input (feature `pointerFrameDrags`): a thumb drag scrolls on
    /// the frame interval's first event and once more at its frame, to the latest point, with every
    /// point between for the velocity, as Chromium delivers rAF-aligned moves with their coalesced
    /// events (`third_party/blink/renderer/platform/widget/input/main_thread_event_queue.cc`).
    /// Nil: every drag event scrolls at once.
    var pointerFrames: () -> FrameInputCoalescers? = { nil }
    /// This thumb drag's consumer of its window's coalescer, from mouse-down to mouse-up.
    private var frameDrag: PointerFrameConsumer?

    private let thumb = CALayer()
    private(set) var thumbRect: CGRect?
    private var input: Input?
    /// Set only by the hover owner (`PointerHover`, cx-3wu5): the pointer
    /// over the shown band now.
    private(set) var isHovered = false
    private var pointerHover: PointerHover?
    private var drag: (grab: CGFloat, width: CGFloat)?
    private(set) var isShown = false
    private let hideTimer: DemandTimer
    /// The window whose overlay host holds this bar's occluder.
    private weak var occludedWindow: NSWindow?
    private var occluderID: String { "strip-scrollbar-\(ObjectIdentifier(self).hashValue)" }

    /// Idle time before `auto` fades out.
    static let idleDelay: Duration = .milliseconds(1200)

    /// `hideClock` runs the `auto` fade-out deadline.
    init(hideClock: any Clock<Duration>) {
        // timer-class-allow: the fade-out runs on the injected scrollbar clock (LayoutRootView's scrollbarClock) the strip suites step; it is armed only by a shown bar's scroll or hover
        hideTimer = DemandTimer(owner: "Layout.stripScrollbar.hide", clock: hideClock)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(thumb)
        thumb.opacity = 0
        setAccessibilityElement(true)
        setAccessibilityRole(.scrollBar)
        setAccessibilityLabel(LayoutStrings.stripScrollbarAccessibility)
        let hover = PointerHover(self) { [weak self] hovering in self?.setHovered(hovering) }
        hover.isHoverable = { [weak self] in self?.thumbRect != nil && self?.input?.mode != .off }
        pointerHover = hover
        // `system` re-resolves on a change of the macOS "Show scroll bars" setting.
        SystemScrollers.observe(self) { [weak self] _ in
            guard let self, let input = self.input, input.mode == .system else { return }
            self.update(input, scrolled: false)
        }
    }

    /// The mode applied now: `system` resolved against the macOS scroller style.
    private static func applied(_ mode: StripScrollbarMode) -> StripScrollbarMode {
        mode.resolved(legacyScrollers: SystemScrollers.nativeStyle == .legacy)
    }
    /// The mode the last `update` applied (a style change compares against it).
    private var appliedMode: StripScrollbarMode?

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    nonisolated override var isFlipped: Bool { true }

    /// Thumb thickness and the track inset from the band's bottom.
    static var thickness: CGFloat { Metrics.space2 }
    static var hoverThickness: CGFloat { Metrics.space3 }
    /// The band that takes the mouse while shown.
    static var bandHeight: CGFloat { Metrics.space5 }
    static var minimumThumbWidth: CGFloat { Metrics.space6 * 2 }

    /// New geometry or offset. `scrolled` is true when the offset moved
    /// (any cause): `auto` flashes the thumb.
    func update(_ input: Input, scrolled: Bool) {
        let previousMode = appliedMode
        self.input = input
        let mode = Self.applied(input.mode)
        appliedMode = mode
        if frame != input.band { frame = input.band }
        let track = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
        thumbRect = StripScrollbarGeometry.thumb(track: track, offset: input.offset, contentWidth: input.contentWidth,
                                                 viewportWidth: input.viewportWidth, minimumThumbWidth: Self.minimumThumbWidth)
        layoutThumb()
        // The band moved, resized or lost its thumb under a possibly still
        // pointer: hover follows before the fade decision reads it.
        pointerHover?.refresh()
        switch mode {
        case .off, .system: // `system` never survives `applied`
            setShown(false)
        case .always:
            setShown(thumbRect != nil)
        case .auto:
            if thumbRect == nil {
                setShown(false)
            } else if scrolled || isHovered || drag != nil || (previousMode != .auto && previousMode != nil) {
                flash()
            }
        }
        syncOccluder()
    }

    private func layoutThumb() {
        guard let rect = thumbRect else { return }
        let thickness = isHovered || drag != nil ? Self.hoverThickness : Self.thickness
        let frame = CGRect(x: rect.minX, y: bounds.height - thickness - Metrics.space1, width: rect.width, height: thickness)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        thumb.frame = frame
        thumb.cornerRadius = thickness / 2
        CATransaction.commit()
    }

    /// Shows the thumb and schedules the `auto` fade-out.
    private func flash() {
        setShown(true)
        guard appliedMode == .auto, !isHovered, drag == nil else {
            hideTimer.cancel()
            return
        }
        hideTimer.scheduleOnMain(after: Self.idleDelay) { [weak self] in
            guard let self, self.appliedMode == .auto, !self.isHovered, self.drag == nil else { return }
            self.setShown(false)
        }
    }

    private func setShown(_ shown: Bool) {
        if !shown { hideTimer.cancel() }
        guard shown != isShown else { return }
        isShown = shown
        syncOccluder()
        applyColors()
        let value: Float = shown ? 1 : 0
        thumb.opacity = value
        _ = Motion.panes.set(thumb, "opacity", to: value, fade: shown ? .fadeIn : .fadeOut, from: shown ? Float(0) : Float(1))
    }

    private func applyColors() {
        performWithTheme {
            thumb.backgroundColor = Palette.textTertiary.withAlphaComponent(isHovered || drag != nil ? 0.7 : 0.5).cgColor
        }
    }

    // Called for the bar's own `isHidden` and for an ancestor's (a screen switch, an empty workspace).
    // visibility-walk-allow: the occluder is input routing (which window rect takes clicks over a page); a hidden bar drops it in this turn
    override func viewDidHide() {
        super.viewDidHide()
        syncOccluder()
    }

    // visibility-walk-allow: as viewDidHide: the shown bar's occluder comes back in this turn
    override func viewDidUnhide() {
        super.viewDidUnhide()
        syncOccluder()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncOccluder()
    }

    /// The shown thumb's band (full band height, so hover thickening stays inside it) in window
    /// coordinates as this bar's occluder, nothing otherwise. A window it left drops it. Also run
    /// when an ancestor moved without an `update` (a screen sliding in or out).
    func syncOccluder() {
        // visibility-walk-allow: the occluder's hit region: a bar under a hidden ancestor must take no clicks over a page
        let rect = isShown && !isHiddenOrHasHiddenAncestor ? thumbRect.map { convert($0, to: nil) } : nil
        // A window in deallocation counts as none: a weak reference to it aborts the runtime.
        let window = self.window.flatMap { $0.isBeingDeallocated ? nil : $0 }
        if let old = occludedWindow, old !== window {
            WindowOverlayHost.existingHost(for: old)?.setOccluder(id: occluderID, rect: nil)
        }
        occludedWindow = window
        guard let window else { return }
        WindowOverlayHost.existingHost(for: window)?.setOccluder(id: occluderID, rect: rect)
    }

    // visibility-walk-allow: the thumb's one layer color, no layout or text measure; cheaper than a deferral
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    // MARK: Mouse

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isShown, thumbRect != nil, !isHidden else { return nil }
        return super.hitTest(point)
    }

    /// A click on a window that is not key still scrolls, like a divider.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Hover came or went (an enter or exit, or the band moved under a
    /// still pointer): the thumb thickens and holds, or it may fade again.
    private func setHovered(_ hovering: Bool) {
        isHovered = hovering
        layoutThumb()
        applyColors()
        if hovering { flash() } else if drag == nil, isShown { flash() }
    }

    override func mouseDown(with event: NSEvent) {
        guard let thumbRect, let input else { return }
        let x = convert(event.locationInWindow, from: nil).x
        if x >= thumbRect.minX, x <= thumbRect.maxX {
            drag = (x - thumbRect.minX, thumbRect.width)
            hideTimer.cancel()
            layoutThumb()
            applyColors()
            beginFrameDrag()
            onDragBegan?()
        } else if let target = StripScrollbarGeometry.pageTarget(clickX: x, thumb: thumbRect, offset: input.offset,
                                                                viewportWidth: input.viewportWidth, snaps: input.snaps) {
            onPage?(target)
        }
    }

    // local-monitor-allow: the thumb drag goes to the window's FrameInputCoalescer (frameDrag), one scroll per frame to the latest point; only a bar with no coalescer (tests, feature off) moves per event
    override func mouseDragged(with event: NSEvent) { // perf-hot: 2ms resize-drag (every thumb drag event)
        guard drag != nil else { return }
        if let frameDrag, frameDrag.post(event) { return }
        guard let offset = thumbOffset(at: event.locationInWindow) else { return }
        onDrag?(offset, event.timestamp)
    }

    override func mouseUp(with event: NSEvent) {
        guard drag != nil else { return }
        // The frame's pending move lands before the release (Chromium's ShouldFlushQueue).
        frameDrag?.flush()
        endFrameDrag()
        drag = nil
        layoutThumb()
        applyColors()
        onDragEnded?(event.timestamp)
        flash()
    }

    /// Leaving the view tree mid-drag: the mouse-up will never arrive here, so the pending moves go.
    override func viewWillMove(toSuperview newSuperview: NSView?) {
        super.viewWillMove(toSuperview: newSuperview)
        if newSuperview == nil { endFrameDrag() }
    }

    /// The strip offset that puts the grabbed thumb point under the pointer at `windowPoint`; nil with no drag.
    private func thumbOffset(at windowPoint: CGPoint) -> CGFloat? {
        guard let drag, let input else { return nil }
        let x = convert(windowPoint, from: nil).x
        let maxOffset = ColumnStripGeometry.maxOffset(contentWidth: input.contentWidth, viewportWidth: input.viewportWidth)
        return StripScrollbarGeometry.offset(forThumbMinX: x - drag.grab, thumbWidth: drag.width, track: bounds, maxOffset: maxOffset)
    }

    /// One delivery of the frame-aligned drag: every point but the latest feeds the velocity at its own
    /// time, then the strip scrolls to the latest, as ``DividerHandleView`` delivers. No allocation: the
    /// points are the delivery's own.
    private func deliver(_ delivery: PointerCoalescedInput) { // perf-hot: 2ms resize-drag (each thumb drag delivery)
        let samples = delivery.samples
        if samples.count > 1 {
            for sample in samples[..<(samples.count - 1)] {
                guard let offset = thumbOffset(at: CGPoint(x: sample.location.x, y: sample.location.y)) else { return }
                onDragSample?(offset, sample.timestamp)
            }
        }
        let latest = delivery.latest
        guard let offset = thumbOffset(at: CGPoint(x: latest.location.x, y: latest.location.y)) else { return }
        onDrag?(offset, latest.timestamp)
    }

    private func beginFrameDrag() {
        endFrameDrag()
        guard let window, let frames = pointerFrames() else { return }
        frameDrag = frames.coalescer(for: window).consumer(owner: "StripScrollbarView.thumbDrag") { [weak self] input in
            self?.deliver(input)
        }
    }

    /// Drops this drag's consumer and anything it still has pending.
    private func endFrameDrag() {
        frameDrag?.cancel()
        frameDrag = nil
    }
}
