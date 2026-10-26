import AppKit
import CmuxNextDesign
import CmuxNextInput
import CmuxNextWakeups
import QuartzCore

/// Draggable handle for a split divider, a column's trailing edge or the gap
/// between two rows. The frame is the hit area; a thin line is drawn in its
/// center for splits.
final class DividerHandleView: NSView {
    enum Kind: Hashable {
        case split(SplitID)
        case columnEdge(ColumnID)
        /// The gap below `RowID` in its column (plans/cmux-next/rows.md Z1).
        case rowEdge(ColumnID, RowID)
    }

    /// A drag's steps. Times are the events' own timestamps, so the release velocity reads one
    /// clock at both ends however late the main thread handles them.
    enum DragEvent {
        case began(NSPoint)
        /// The pointer passed `point` at `time` before a later move of the same delivery: it feeds
        /// the release velocity only.
        case sampled(NSPoint, time: CFTimeInterval)
        /// The pointer was at `point` at `time`: the real sample, which the velocity, snaps and the
        /// release read. The divider is drawn at `shown`, the pointer resampled at the frame's time
        /// (`input.resampleDrags`); nil draws it at `point`.
        case moved(NSPoint, time: CFTimeInterval, shown: NSPoint? = nil)
        /// The pointer went up at `point` at `time`.
        case ended(NSPoint, time: CFTimeInterval)
        case doubleClick
    }

    let kind: Kind
    private(set) var axis: SplitAxis
    /// The screen sets it on every sync (a focus move too): only a new thickness moves the line.
    var lineThickness: CGFloat = 1 { didSet { if lineThickness != oldValue { needsLayout = true } } }
    /// Draws the split line at rest. Off while panes have a border (the
    /// borders separate them); hover and drag still show the line.
    var showsIdleLine = true {
        didSet { if showsIdleLine != oldValue { applyColors() } }
    }
    /// Shows the line on hover and while dragging. Off under
    /// `layout.paneSeparation` none: the resize cursor is the only cue.
    var showsActiveLine = true {
        didSet { if showsActiveLine != oldValue { applyColors() } }
    }
    var onDrag: ((DragEvent) -> Void)?
    /// The windows' frame-aligned pointer input (feature `pointerFrameDrags`): a drag moves the
    /// divider on the frame interval's first event and once more at its frame, to the latest point,
    /// with every point between for the velocity, as Chromium delivers rAF-aligned moves
    /// (`third_party/blink/renderer/platform/widget/input/main_thread_event_queue.cc`). Nil: every
    /// drag event moves it at once.
    var pointerFrames: () -> FrameInputCoalescers? = { nil }
    /// This drag's consumer of its window's coalescer, from mouse-down to mouse-up.
    private var frameDrag: PointerFrameConsumer?
    /// A new drag's resampler for where the divider is drawn (``LayoutRootView/dragResampler``); nil
    /// draws it at the real pointer. Read once per drag, on mouse-down, with frame-aligned input only.
    var dragResampler: () -> DragResampler? = { nil }
    /// This drag's resampler, from mouse-down to mouse-up.
    private var resampler: DragResampler?
    /// The screen's uncovered rect and this handle's scroll area window when it was last placed
    /// (`applyPresentation`): its hidden state and cursor clip follow from them and the frame, so
    /// equal ones skip the work.
    var placedClips: [CGRect?]?
    /// The pointer crossed this handle's tracking area (the enter or exit). The
    /// screen that owns the handles decides hover from that event's point and
    /// the current frames (`ScreenContentView.refreshDividerHover`); the handle
    /// keeps no hover of its own, because a layout change can move it under a
    /// still pointer.
    var onPointerChange: ((NSEvent) -> Void)?

    private let line = CALayer()
    private(set) var isHovered = false { didSet { if isHovered != oldValue { applyColors() } } }
    private var isDragging = false { didSet { applyColors() } }
    private var trackingArea: NSTrackingArea?

    init(kind: Kind, axis: SplitAxis) {
        self.kind = kind
        self.axis = axis
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(line)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        switch kind {
        case .split(let split):
            setAccessibilityLabel(LayoutStrings.dividerAccessibility)
            setAccessibilityIdentifier("cmux.pane.divider.\(split.rawValue)")
        case .columnEdge(let column):
            setAccessibilityLabel(LayoutStrings.columnEdgeAccessibility)
            setAccessibilityIdentifier("cmux.pane.columnEdge.\(column.rawValue)")
        case .rowEdge(let column, let row):
            setAccessibilityLabel(LayoutStrings.rowEdgeAccessibility)
            setAccessibilityIdentifier("cmux.pane.rowEdge.\(column.rawValue).\(row.rawValue)")
        }
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    nonisolated override var isFlipped: Bool { true }

    func setAxis(_ axis: SplitAxis) {
        guard self.axis != axis else { return }
        self.axis = axis
        window?.invalidateCursorRects(for: self)
        needsLayout = true
    }

    /// Layout calls since the handle was made (tests: a focus move lays out no handle, cx-3j8y.2).
    private(set) var layoutCount = 0

    override func layout() {
        super.layout()
        layoutCount += 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        line.frame = lineFrame
        CATransaction.commit()
    }

    /// A column edge sits in a gap and draws only while hovered or dragged.
    private var isColumnEdge: Bool {
        switch kind {
        case .columnEdge: true
        case .split, .rowEdge: false
        }
    }

    private var isRowEdge: Bool {
        if case .rowEdge = kind { return true }
        return false
    }

    private var isEdgeHandle: Bool { isColumnEdge || isRowEdge }

    override func setFrameSize(_ newSize: NSSize) {
        let old = frame.size
        super.setFrameSize(newSize)
        if newSize != old { needsLayout = true }
    }

    /// The part of the superview where the handle may take the pointer; nil for all of it. A strip
    /// divider that runs on under a docked column stops where the dock begins: AppKit cursor rects
    /// ignore the views above, so its whole frame showed a resize cursor over the docked pane.
    var cursorClip: CGRect? {
        didSet { if cursorClip != oldValue { window?.invalidateCursorRects(for: self) } }
    }

    /// Where the handle shows its resize cursor, in its own coordinates: its bounds within `cursorClip`.
    var cursorRectInBounds: CGRect {
        guard let cursorClip else { return bounds }
        let rect = bounds.intersection(convert(cursorClip, from: superview))
        return rect.isNull ? .zero : rect
    }

    /// AppKit's cursor rect and tracking area rebuilds of this handle, cumulative (StripPanContainerTests:
    /// a strip pan on the motion container makes none).
    private(set) var cursorRectResets = 0
    private(set) var trackingAreaUpdates = 0

    override func resetCursorRects() {
        cursorRectResets += 1
        let rect = cursorRectInBounds
        guard !rect.isEmpty else { return }
        if #available(macOS 15, *) {
            addCursorRect(rect, cursor: axis == .horizontal ? .columnResize : .rowResize)
        } else {
            addCursorRect(rect, cursor: axis == .horizontal ? .resizeLeftRight : .resizeUpDown)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreaUpdates += 1
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    /// The drawn line in the superview's coordinates. It is native UI that
    /// must show above Chromium pages (an occlusion hole), unlike the rest
    /// of the hit area.
    var lineFrameInSuperview: CGRect {
        convert(lineFrame, to: superview)
    }

    private var lineFrame: CGRect {
        let t = isColumnEdge ? LayoutStyle.columnEdgeLineThickness(dividerThickness: lineThickness) : lineThickness
        return switch axis {
        case .horizontal: CGRect(x: (bounds.width - t) / 2, y: 0, width: t, height: bounds.height)
        case .vertical: CGRect(x: 0, y: (bounds.height - t) / 2, width: bounds.width, height: t)
        }
    }

    /// The line's color as drawn now.
    var lineColor: CGColor? { line.backgroundColor }

    /// Whether the native line currently contributes pixels. Edge handles use
    /// a transparent line at rest and only draw while hovered or dragged; the
    /// overlay must not reserve a Chromium occlusion hole for that clear state.
    var isLineVisible: Bool {
        // Use the presentation color while the hover fade is running. The
        // page must remain covered until the last visible native pixel fades.
        guard let color = (line.presentation() ?? line).backgroundColor else { return false }
        return color.alpha > 0.001 && line.opacity > 0.001
    }

    /// Set only by the owning screen's hover pass.
    func setHovered(_ hovered: Bool) { isHovered = hovered }

    override func mouseEntered(with event: NSEvent) { onPointerChange?(event) }
    override func mouseExited(with event: NSEvent) { onPointerChange?(event) }

    /// Leaving the view tree mid-drag: the mouse-up will never arrive here,
    /// so the drag state ends with the view (the screen ends the gesture).
    override func viewWillMove(toSuperview newSuperview: NSView?) {
        super.viewWillMove(toSuperview: newSuperview)
        if newSuperview == nil {
            isDragging = false
            endFrameDrag()
            isHovered = false
            // Its render-server springs end now, so their landings run (`ScreenContentView.springDivider`).
            if let layer { for keyPath in ["position", "bounds.size"] { RenderSpring.stop(layer, keyPath) } }
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// A press here drags the divider, also where the handle reaches into the titlebar band:
    /// it never moves the window (`TitlebarDragPolicy`), and its double-click stays its own.
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDrag?(.doubleClick)
            return
        }
        isDragging = true
        endFrameDrag()
        frameDrag = window.flatMap { pointerFrames()?.coalescer(for: $0) }?.frameTimedConsumer(owner: "DividerHandleView") { [weak self] input, frame in
            self?.deliver(input, at: frame)
        }
        resampler = frameDrag == nil ? nil : dragResampler()
        onDrag?(.began(event.locationInWindow))
    }

    override func mouseDragged(with event: NSEvent) { // perf-hot: 2ms resize-drag (every drag event)
        guard isDragging else { return }
        if let frameDrag {
            frameDrag.post(event)
        } else {
            onDrag?(.moved(event.locationInWindow, time: event.timestamp))
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        // The frame's pending move lands before the release (Chromium's ShouldFlushQueue).
        frameDrag?.flush()
        endFrameDrag()
        isDragging = false
        onDrag?(.ended(event.locationInWindow, time: event.timestamp))
    }

    /// One delivery of the frame-aligned drag: every point but the latest feeds the velocity, then
    /// the divider moves to the latest, drawn at the pointer resampled at `frame` while a resampler
    /// runs. No allocation: the points are the delivery's own.
    private func deliver(_ input: PointerCoalescedInput, at frame: PointerFrameTime) { // perf-hot: 2ms resize-drag (each leading or trailing delivery)
        guard isDragging else { return }
        let samples = input.samples
        if samples.count > 1 {
            for sample in samples[..<(samples.count - 1)] {
                onDrag?(.sampled(NSPoint(x: sample.location.x, y: sample.location.y), time: sample.timestamp))
            }
        }
        let latest = input.latest
        let shown = resampler?.points(for: input, at: frame).visualPoint
        onDrag?(.moved(NSPoint(x: latest.location.x, y: latest.location.y), time: latest.timestamp,
                       shown: shown.map { NSPoint(x: $0.x, y: $0.y) }))
    }

    /// Drops this drag's consumer and anything it still has pending.
    private func endFrameDrag() {
        frameDrag?.cancel()
        frameDrag = nil
        resampler = nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        let isEdge = isEdgeHandle
        performWithTheme {
            let active = (isHovered || isDragging) && showsActiveLine
            let color: NSColor
            if isEdge {
                if active {
                    color = Palette.focusRing.withAlphaComponent(isRowEdge ? 0.6 : 0.45)
                } else if isRowEdge, showsIdleLine {
                    color = Palette.separator.withAlphaComponent(0.32)
                } else {
                    color = .clear
                }
            } else {
                color = active ? Palette.focusRing.withAlphaComponent(0.6) : ((showsIdleLine || Palette.surfaceOverride(.splitDivider) != nil) ? (Palette.surfaceOverride(.splitDivider) ?? Palette.separator) : .clear)
            }
            Motion.feedback.transaction(.hover) {
                line.backgroundColor = color.cgColor
                line.cornerRadius = isEdge ? 1 : 0
            }
        }
    }
}
