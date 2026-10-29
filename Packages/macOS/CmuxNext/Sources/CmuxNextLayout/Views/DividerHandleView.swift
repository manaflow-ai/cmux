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
    /// clock at both ends however late the main thread handles them. Every pointer event carries
    /// the modifier keys held (resize-modifiers.md).
    enum DragEvent {
        case began(NSPoint, NSEvent.ModifierFlags)
        /// The pointer passed `point` at `time` before a later move of the same delivery: it feeds
        /// the release velocity only.
        case sampled(NSPoint, time: CFTimeInterval)
        /// The pointer was at `point` at `time`: the real sample, which the velocity, snaps and the
        /// release read. The divider is drawn at `shown`, the pointer resampled at the frame's time
        /// (`input.resampleDrags`); nil draws it at `point`.
        case moved(NSPoint, NSEvent.ModifierFlags, time: CFTimeInterval, shown: NSPoint? = nil)
        /// The pointer went up at `point` at `time`.
        case ended(NSPoint, NSEvent.ModifierFlags, time: CFTimeInterval)
        /// A modifier key went down or up mid-drag, with no pointer move.
        case modifiersChanged(NSEvent.ModifierFlags)
        /// Escape mid-drag: the drag goes back to where it began; the release that follows is ignored.
        case cancelled
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

    /// Render-server spring calls on the handle's layer that have not landed yet (``springToRest(_:spring:landed:)``).
    private(set) var renderSpringsInFlight = 0
    /// The handle's frame is at rest and Core Animation shows it springing there: it takes no hover and
    /// shows no resize cursor until it lands (``ScreenDividers/refreshHover(at:)``).
    var isOnRenderSpring: Bool { renderSpringsInFlight > 0 }
    /// Frame assignments since the handle was made (tests: a render-server spring sets one, in its start's
    /// turn, and none until it lands).
    private(set) var frameSetCount = 0
    override var frame: NSRect { didSet { frameSetCount += 1 } }

    private let line = CALayer()
    private(set) var isHovered = false { didSet { if isHovered != oldValue { applyColors() } } }
    private var isDragging = false { didSet { applyColors() } }
    /// Escape and modifier keys while a drag runs: this handle is never first responder, so it
    /// would hear neither. Installed on the press, removed when the drag ends.
    private var keyMonitor: Any?
    /// The modifier keys held as the drag's last event said (a frame-aligned delivery carries none).
    private var dragModifiers: NSEvent.ModifierFlags = []

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
        // The hover area, once: `.inVisibleRect` follows every frame change. The cursor area follows its own
        // rect from the frame and clip setters (``placeCursorArea()``), so no `updateTrackingAreas` override.
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
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
        if isHovered { resizeCursor.set() }
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
        if newSize != old {
            needsLayout = true
            placeCursorArea()
        }
    }

    /// A clipped handle's cursor area is in its own coordinates, so a move changes where the clip falls.
    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        if cursorClip != nil { placeCursorArea() }
    }

    /// The part of the superview where the handle may take the pointer; nil for all of it. A strip
    /// divider that runs on under a docked column stops where the dock begins: AppKit's tracking areas
    /// ignore the views above, so its whole frame showed a resize cursor over the docked pane.
    /// The handle's cursor area follows it (``cursorArea``).
    var cursorClip: CGRect? {
        didSet { placeCursorArea() }
    }

    /// Where the handle shows its resize cursor, in its own coordinates: its bounds within `cursorClip`.
    var cursorRectInBounds: CGRect {
        guard let cursorClip else { return bounds }
        let rect = bounds.intersection(convert(cursorClip, from: superview))
        return rect.isNull ? .zero : rect
    }

    /// The `.cursorUpdate` area: exactly ``cursorRectInBounds``, as the cursor rect was, so the pointer
    /// crossing the clip edge enters or leaves it and AppKit asks the view under the pointer for its
    /// cursor (a docked pane's, or this handle's resize cursor). Nil while that rect is empty.
    private(set) var cursorArea: NSTrackingArea?

    /// Places ``cursorArea`` at ``cursorRectInBounds`` when that rect changed: a tracking area swap, never
    /// a rebuild of the window's cursor rects, and nothing when the rect is the same.
    private func placeCursorArea() {
        let rect = cursorRectInBounds
        if let cursorArea {
            guard cursorArea.rect != rect else { return }
            removeTrackingArea(cursorArea)
            self.cursorArea = nil
        }
        guard !rect.isEmpty else { return }
        let area = NSTrackingArea(rect: rect, options: [.cursorUpdate, .activeInKeyWindow], owner: self)
        addTrackingArea(area)
        cursorArea = area
    }

    /// The resize cursor across the handle's axis.
    var resizeCursor: NSCursor {
        if #available(macOS 15, *) { return axis == .horizontal ? .columnResize : .rowResize }
        return axis == .horizontal ? .resizeLeftRight : .resizeUpDown
    }

    /// The cursor the handle shows at `point` (its own coordinates): the resize cursor within
    /// ``cursorRectInBounds``; none mid-spring, where the frame is at rest but the handle shows
    /// elsewhere (its landing hovers it and brings the cursor back, ``setHovered(_:)``).
    func cursor(at point: CGPoint) -> NSCursor? {
        guard !isOnRenderSpring, cursorRectInBounds.contains(point) else { return nil }
        return resizeCursor
    }

    /// The pointer entered ``cursorArea``: no cursor rects, so a frame change during a
    /// drag or a strip pan rebuilds none of the window's. Mid-spring it leaves the cursor alone.
    override func cursorUpdate(with event: NSEvent) {
        cursor(at: convert(event.locationInWindow, from: nil))?.set()
    }

    /// The drawn line in the superview's coordinates. It is native UI that
    /// must show above Chromium pages (an occlusion hole), unlike the rest
    /// of the hit area.
    var lineFrameInSuperview: CGRect {
        convert(lineFrame, to: superview)
    }

    private var lineFrame: CGRect { lineRect(in: bounds.size) }

    /// The line's frame in a handle of `size`: centered across the axis, the handle's whole length along it.
    private func lineRect(in size: CGSize) -> CGRect {
        let t = isColumnEdge ? LayoutStyle.columnEdgeLineThickness(dividerThickness: lineThickness) : lineThickness
        return switch axis {
        case .horizontal: CGRect(x: (size.width - t) / 2, y: 0, width: t, height: size.height)
        case .vertical: CGRect(x: 0, y: (size.height - t) / 2, width: size.width, height: t)
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

    /// Set only by the owning screen's hover pass. A handle that becomes hovered under a still pointer
    /// (a spring landed, a layout moved it there) gets no cursor update: it shows its cursor now.
    func setHovered(_ hovered: Bool) {
        if hovered, !isHovered { resizeCursor.set() }
        isHovered = hovered
    }

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
            stopKeyMonitor()
            // Its render-server springs end now; their landings still run (``springToRest(_:spring:landed:)``).
            if let layer {
                for keyPath in Self.renderSpringKeyPaths {
                    RenderSpring.stop(layer, keyPath)
                    RenderSpring.stop(line, keyPath)
                }
            }
        }
    }

    /// The key paths a render-server spring of the handle animates, on its backing layer and on its line.
    static let renderSpringKeyPaths = ["position", "bounds.size", "opacity"]

    /// Lets the render server show the handle, placed at rest in this turn (``ScreenDividers/place(_:_:at:alpha:uncovered:force:)``
    /// set its frame, alpha, hidden state and clips, its one frame set until it lands), springing there from
    /// `move.from` at `move.velocity` (alpha `move.fromAlpha`) on `spring`, the token of the panes beside it:
    /// additive springs of its backing layer's position, size and opacity (``NSView/renderSpringMoves(from:velocity:)``)
    /// and of its line's position and size (the line does not scale with the layer), from one begin time, as
    /// Chromium's compositor runs a layer's transform animation off the main thread (`cc/animation/animation_host.h`).
    /// A spring on a handle already springing retargets; the springs still running keep their velocity.
    /// `landed` runs once, when this call's springs ended or a newer call took over (`RenderSpring.Completion`),
    /// after the handle shows its cursor at its rest frame again.
    func springToRest(_ move: SplitMotion.RenderMove, spring: RenderSpring, landed: @escaping @MainActor @Sendable () -> Void) {
        renderSpringsInFlight += 1
        let finish: RenderSpring.Completion = { [weak self] _ in
            self?.renderSpringLanded()
            landed()
        }
        guard let layer, let superview else { return finish(true) }
        var moves = renderSpringMoves(from: move.from, velocity: move.velocity)
        if move.fromAlpha != move.toAlpha { moves.append(RenderSpring.Move(layer, .opacity, from: move.fromAlpha, to: move.toAlpha)) }
        // The layer's start size and size velocity, as its own size springs read them.
        let start = superview.convertToLayer(move.from), rest = superview.convertToLayer(frame), size = layer.bounds.size
        let fromSize = CGSize(width: size.width + start.width - rest.width, height: size.height + start.height - rest.height)
        let sizeRate = RenderLayerAxes(superview).velocity(move.velocity, anchor: layer.anchorPoint).size
        moves += lineMoves(from: fromSize, sizeVelocity: sizeRate)
        spring.animateGroup(moves, in: self, completion: finish)
    }

    /// The line's springs from where it shows in a handle of `size` growing at `sizeVelocity` to its rest in
    /// the handle's bounds. ``lineRect(in:)`` is linear in the size, so its rate is its change over one second.
    private func lineMoves(from size: CGSize, sizeVelocity: CGSize) -> [RenderSpring.Move] {
        let rest = lineRect(in: bounds.size), start = lineRect(in: size)
        let ahead = lineRect(in: CGSize(width: size.width + sizeVelocity.width, height: size.height + sizeVelocity.height))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        line.frame = rest
        CATransaction.commit()
        let anchor = line.anchorPoint
        let restAt = RenderLayerAxes.position(of: rest, anchor: anchor), startAt = RenderLayerAxes.position(of: start, anchor: anchor)
        let aheadAt = RenderLayerAxes.position(of: ahead, anchor: anchor)
        return [
            RenderSpring.Move(line, .positionX, from: startAt.x, to: restAt.x, velocity: aheadAt.x - startAt.x),
            RenderSpring.Move(line, .positionY, from: startAt.y, to: restAt.y, velocity: aheadAt.y - startAt.y),
            RenderSpring.Move(line, .boundsWidth, from: start.width, to: rest.width, velocity: ahead.width - start.width),
            RenderSpring.Move(line, .boundsHeight, from: start.height, to: rest.height, velocity: ahead.height - start.height),
        ]
    }

    /// The handle's and its line's position and size springs end (a fade runs on): its CPU frame takes what
    /// shows (`ScreenContentView.takeRenderSpringsBack`).
    func stopRenderMoves() {
        guard let layer else { return }
        for target in [layer, line] { ScreenContentView.stopMoveSprings(target) }
    }

    /// The line's layer, for tests: it springs with the handle (``springToRest(_:spring:landed:)``).
    var lineLayer: CALayer { line }

    /// One render-server spring call landed: after the last, the resize cursor shows at the rest frame
    /// (``cursor(at:)``; the screen's hover pass after the landing sets it under a still pointer).
    private func renderSpringLanded() {
        renderSpringsInFlight -= 1
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
        dragModifiers = event.modifierFlags
        startKeyMonitor()
        onDrag?(.began(event.locationInWindow, event.modifierFlags))
    }

    override func mouseDragged(with event: NSEvent) { // perf-hot: 2ms resize-drag (every drag event) // local-monitor-allow: the drag goes to the window's FrameInputCoalescer (frameDrag); only a root with no coalescer (tests) moves per event
        guard isDragging else { return }
        dragModifiers = event.modifierFlags
        if let frameDrag {
            frameDrag.post(event)
        } else {
            onDrag?(.moved(event.locationInWindow, event.modifierFlags, time: event.timestamp))
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        // The frame's pending move lands before the release (Chromium's ShouldFlushQueue).
        frameDrag?.flush()
        endFrameDrag()
        isDragging = false
        stopKeyMonitor()
        onDrag?(.ended(event.locationInWindow, event.modifierFlags, time: event.timestamp))
    }

    override func flagsChanged(with event: NSEvent) {
        guard isDragging else { return super.flagsChanged(with: event) }
        dragModifiers = event.modifierFlags
        onDrag?(.modifiersChanged(event.modifierFlags))
    }

    /// Escape mid-drag (the key monitor; tests call it directly).
    override func cancelOperation(_ sender: Any?) {
        guard isDragging else { return }
        endFrameDrag()
        isDragging = false
        stopKeyMonitor()
        onDrag?(.cancelled)
    }

    private func startKeyMonitor() {
        stopKeyMonitor()
        // local-monitor-allow: Escape and modifier keys only while this handle drags (installed on the press, removed when the drag ends); the handle is never first responder, so it hears neither otherwise
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, self.isDragging else { return event }
            if event.type == .flagsChanged {
                self.flagsChanged(with: event)
                return event
            }
            // Escape cancels the drag and goes no further; other keys go on as usual.
            if event.keyCode == 53 { self.cancelOperation(nil) }
            return event.keyCode == 53 ? nil : event
        }
    }

    private func stopKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
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
        onDrag?(.moved(NSPoint(x: latest.location.x, y: latest.location.y), dragModifiers, time: latest.timestamp,
                       shown: shown.map { NSPoint(x: $0.x, y: $0.y) }))
    }

    /// Drops this drag's consumer and anything it still has pending.
    private func endFrameDrag() {
        frameDrag?.cancel()
        frameDrag = nil
        resampler = nil
    }

    override func viewDidChangeEffectiveAppearance() { // visibility-walk-allow: one line layer's color and corner, no layout or text measure; cheaper than a deferral
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
