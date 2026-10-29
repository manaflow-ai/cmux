import AppKit
import CmuxNextDesign
import CmuxNextCompat
import CmuxNextInput
import CmuxNextWakeups

/// Strip on the sidebar's edge facing the content that resizes it. Invisible until
/// the pointer is over it; then a hairline fades in (and stays while
/// dragging), so the edge never shows as a seam at rest.
///
/// The strip is wider than the line and lies across the edge (`SidebarResizeBand`), so the
/// container mounts it in its superview: inside the container AppKit would clip the outer part
/// out of hit testing, cursor updates and hover (u2255).
final class SidebarResizeHandle: NSView {
    enum Phase {
        case began
        case changed(CGFloat)
        case ended
    }

    var onDrag: ((Phase) -> Void)?
    /// The windows' frame-aligned pointer input (feature `pointerFrameDrags`): a drag resizes on a
    /// frame interval's first event and once more at its frame, to the latest point, as Chromium
    /// delivers rAF-aligned moves (`third_party/blink/renderer/platform/widget/input/
    /// main_thread_event_queue.cc`). Nil: every drag event resizes at once.
    var pointerFrames: FrameInputCoalescers?
    /// This drag's consumer of its window's coalescer, from mouse-down to mouse-up.
    private var frameDrag: PointerFrameConsumer?
    private(set) var isDragging = false { didSet { updateLine() } }
    /// Set by the hover owner (`PointerHover`, cx-3wu5).
    private(set) var isHovered = false { didSet { updateLine() } }
    private var pointerHover: PointerHover?
    private var startX: CGFloat = 0
    private let line = CALayer()

    /// Width of the line at rest (`sidebar.border`); 0 shows it only on
    /// hover or while dragging.
    /// Where the sidebar's edge is, from the strip's minX: the line is drawn centered on it.
    var edgeOffset: CGFloat = 0 {
        didSet { if edgeOffset != oldValue { needsLayout = true } }
    }

    var restingLineWidth: CGFloat = 0 {
        didSet {
            guard restingLineWidth != oldValue else { return }
            needsLayout = true
            updateLine()
        }
    }

    /// The hairline shows at rest when the sidebar border is on, else only
    /// on hover or while dragging, and never as hover feedback beside the
    /// curved main pane: the card's edge is the seam there. The hit area and
    /// the resize cursor stay.
    var isLineVisible: Bool { restingLineWidth > 0 || ((isHovered || isDragging) && !Metrics.mainPaneCurved) }

    /// The drawn width: the border's, else the divider hairline.
    var lineWidth: CGFloat { restingLineWidth > 0 ? restingLineWidth : Metrics.lineWidth(Metrics.dividerThickness) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        line.opacity = 0
        layer?.addSublayer(line)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel(Strings.resize)
        setAccessibilityIdentifier("cmux.sidebar.resize")
        pointerHover = PointerHover(self) { [weak self] hovering in self?.setHovered(hovering) }
        addCursorUpdateArea()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The resize cursor, set when the pointer enters (``addCursorUpdateArea(_:)``): no cursor rects
    /// for the window to rebuild while the sidebar's width follows a drag.
    override func cursorUpdate(with event: NSEvent) {
        if #available(macOS 15, *) { NSCursor.columnResize.set() } else { NSCursor.resizeLeftRight.set() }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let width = lineWidth
        line.frame = CGRect(x: edgeOffset - width / 2, y: 0, width: width, height: bounds.height)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() { // visibility-walk-allow: sets the hairline's layer color and invalidates its layout; nothing measures
        super.viewDidChangeEffectiveAppearance()
        applyLineTheme()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyLineTheme()
    }

    /// The hairline's color and width both go through the border metric
    /// (`Palette.separator`, `Metrics.lineWidth`): a borders change repaints
    /// here, and the relayout picks up the width.
    private func applyLineTheme() {
        performWithTheme { line.backgroundColor = Palette.separator.cgColor }
        needsLayout = true
    }

    func setHovered(_ hovered: Bool) { isHovered = hovered }

    /// Windows above this one that pass hover through: the catcher panels over pages
    /// (`DividerMouseCatchers`). They cover the band, so without them the hover reads as occluded.
    var hoverPassThroughWindows: () -> Set<Int> = { [] } {
        didSet { pointerHover?.passThroughWindows = hoverPassThroughWindows }
    }

    /// Recomputes the hover now (the catcher panels moved under a still pointer).
    func refreshHover() { pointerHover?.refresh() }

    /// Hidden with the sidebar under a still pointer: no exit comes.
    override func viewDidHide() { // visibility-walk-allow: the hover owner's hit test (PointerHover.refresh): a hidden handle gets no exit
        super.viewDidHide()
        pointerHover?.refresh()
    }

    override func viewDidUnhide() { // visibility-walk-allow: the hover owner's hit test (PointerHover.refresh) under a still pointer
        super.viewDidUnhide()
        pointerHover?.refresh()
    }

    private func updateLine() {
        let target: Float = isLineVisible ? 1 : 0
        guard line.opacity != target else { return }
        Motion.sidebar.set(line, "opacity", to: target, fade: .hover)
    }

    /// A press here resizes the sidebar, also in the titlebar band: it never moves the window
    /// (`TitlebarDragPolicy`).
    override var mouseDownCanMoveWindow: Bool { false }

    /// The press that takes key back from a focused Chromium page (a child window) starts the
    /// drag, as on a pane divider; otherwise it only brought this window forward.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        isDragging = true
        startX = event.locationInWindow.x
        endFrameDrag()
        frameDrag = window.flatMap { pointerFrames?.coalescer(for: $0) }?.consumer(owner: "SidebarResizeHandle") { [weak self] input in
            self?.deliver(input)
        }
        onDrag?(.began)
    }

    // local-monitor-allow: with pointerFrameDrags the drag is the window's FrameInputCoalescer consumer (frameDrag); off, each event resizes
    override func mouseDragged(with event: NSEvent) { // perf-hot: 2ms resize-drag (every drag event)
        guard isDragging else { return }
        if let frameDrag {
            frameDrag.post(event)
        } else {
            onDrag?(.changed(event.locationInWindow.x - startX))
        }
    }

    /// One delivery of the frame-aligned drag: the width follows the latest point.
    private func deliver(_ input: PointerCoalescedInput) { // perf-hot: 2ms resize-drag (each leading or trailing delivery)
        guard isDragging else { return }
        onDrag?(.changed(input.latest.location.x - startX))
    }

    /// Ends the drag early (it hid the sidebar); later drag events for
    /// this press are ignored.
    func endDrag() {
        isDragging = false
        endFrameDrag()
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        // The frame's pending resize lands before the release (Chromium's ShouldFlushQueue).
        frameDrag?.flush()
        endFrameDrag()
        // The flushed resize may have hidden the sidebar and ended the drag.
        guard isDragging else { return }
        isDragging = false
        onDrag?(.ended)
    }

    /// Drops this drag's consumer and anything it still has pending.
    private func endFrameDrag() {
        frameDrag?.cancel()
        frameDrag = nil
    }
}
