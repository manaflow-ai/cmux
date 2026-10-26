import AppKit
import CmuxNextDesign
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

    enum DragEvent {
        case began(NSPoint)
        case moved(NSPoint)
        case ended(NSPoint)
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

    /// Render-server spring calls on the handle's layer that have not landed yet (``springOnRenderServer``).
    private(set) var renderSpringsInFlight = 0
    /// The handle's frame is at rest and Core Animation shows it springing there: it takes no hover and
    /// shows no resize cursor until it lands (``ScreenDividers/refreshHover(at:)``).
    var isOnRenderSpring: Bool { renderSpringsInFlight > 0 }
    /// Frame assignments since the handle was made (tests: a render-server spring sets one, in its start's
    /// turn, and none until it lands, p03-rendering-024).
    private(set) var frameSetCount = 0
    override var frame: NSRect { didSet { frameSetCount += 1 } }

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

    override func resetCursorRects() {
        let rect = cursorRectInBounds
        // Mid-spring the frame is at rest but the handle shows elsewhere: its landing brings the cursor back.
        guard !rect.isEmpty, !isOnRenderSpring else { return }
        if #available(macOS 15, *) {
            addCursorRect(rect, cursor: axis == .horizontal ? .columnResize : .rowResize)
        } else {
            addCursorRect(rect, cursor: axis == .horizontal ? .resizeLeftRight : .resizeUpDown)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
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
            isHovered = false
            // Its render-server springs end now; their landings still run (``springOnRenderServer``).
            if let layer, isOnRenderSpring {
                for keyPath in Self.renderSpringKeyPaths {
                    RenderSpring.stop(layer, keyPath)
                    RenderSpring.stop(line, keyPath)
                }
            }
        }
    }

    /// The key paths a render-server spring of the handle animates, on its backing layer and on its line.
    static let renderSpringKeyPaths = ["position", "bounds.size", "opacity"]

    /// Lets the render server show the handle springing to its frame from `from` (its superview's
    /// coordinates, alpha `fromAlpha`) on `spring`, the token of the panes beside it. The frame, alpha, hidden
    /// state and clips are at rest already: ``ScreenDividers/place(_:_:at:alpha:uncovered:force:)`` set them in
    /// this turn, the handle's one frame set until it lands. Additive springs of its backing layer's position,
    /// size and opacity and of its line's position and size (the line does not scale with the layer) start
    /// from one begin time, as Chromium's compositor runs a layer's transform animation off the main thread
    /// (`cc/animation/animation_host.h`). A spring on a handle already springing retargets; the springs still
    /// running keep their velocity. `landed` runs once, when this call's springs ended or a newer call took
    /// over (`RenderSpring.Completion`), after the handle's cursor rects follow its rest frame again.
    func springOnRenderServer(from: CGRect, alpha fromAlpha: CGFloat, spring: RenderSpring,
                              landed: @escaping @MainActor @Sendable () -> Void) {
        renderSpringsInFlight += 1
        window?.invalidateCursorRects(for: self)
        let finish: RenderSpring.Completion = { [weak self] _ in
            self?.renderSpringLanded()
            landed()
        }
        guard let layer else { return finish(true) }
        // AppKit keeps a layer-backed view's layer frame equal to its frame: `from` is the layer's start frame.
        let rest = frame
        let restLine = lineRect(in: rest.size), fromLine = lineRect(in: from.size)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        line.frame = restLine
        CATransaction.commit()
        var moves = [RenderSpring.Move(layer, "position", from: Self.position(of: from, anchor: layer.anchorPoint), to: layer.position),
                     RenderSpring.Move(layer, "bounds.size", from: from.size, to: layer.bounds.size),
                     RenderSpring.Move(line, "position", from: Self.position(of: fromLine, anchor: line.anchorPoint), to: line.position),
                     RenderSpring.Move(line, "bounds.size", from: fromLine.size, to: line.bounds.size)]
        if fromAlpha != alphaValue { moves.append(RenderSpring.Move(layer, "opacity", from: fromAlpha, to: alphaValue)) }
        spring.animateGroup(moves, in: self, completion: finish)
    }

    /// A layer's position for `frame` with `anchor` (unit coordinates of its bounds).
    private static func position(of frame: CGRect, anchor: CGPoint) -> CGPoint {
        CGPoint(x: frame.minX + anchor.x * frame.width, y: frame.minY + anchor.y * frame.height)
    }

    /// The line's layer, for tests: it springs with the handle (``springOnRenderServer``).
    var lineLayer: CALayer { line }

    /// One render-server spring call landed: after the last, the resize cursor shows at the rest frame.
    private func renderSpringLanded() {
        renderSpringsInFlight -= 1
        if renderSpringsInFlight == 0 { window?.invalidateCursorRects(for: self) }
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
        onDrag?(.began(event.locationInWindow))
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        onDrag?(.moved(event.locationInWindow))
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        isDragging = false
        onDrag?(.ended(event.locationInWindow))
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
