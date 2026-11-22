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
    var lineThickness: CGFloat = 1 { didSet { needsLayout = true } }
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
    /// The pointer crossed this handle's tracking area. The screen that owns
    /// the handles decides hover from the pointer and the current frames
    /// (`ScreenContentView.refreshDividerHover`); the handle keeps no hover
    /// of its own, because a layout change can move it under a still pointer.
    var onPointerChange: (() -> Void)?

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
        case .split: setAccessibilityLabel(LayoutStrings.dividerAccessibility)
        case .columnEdge: setAccessibilityLabel(LayoutStrings.columnEdgeAccessibility)
        case .rowEdge: setAccessibilityLabel(LayoutStrings.rowEdgeAccessibility)
        }
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    func setAxis(_ axis: SplitAxis) {
        guard self.axis != axis else { return }
        self.axis = axis
        window?.invalidateCursorRects(for: self)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        line.frame = lineFrame
        CATransaction.commit()
    }

    /// A column edge or a row edge: it sits in a gap and draws only while
    /// hovered or dragged.
    private var isColumnEdge: Bool {
        switch kind {
        case .columnEdge, .rowEdge: true
        case .split: false
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: axis == .horizontal ? .columnResize : .rowResize)
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

    private var lineFrame: CGRect {
        let t = isColumnEdge ? max(lineThickness, 2) : lineThickness
        return switch axis {
        case .horizontal: CGRect(x: (bounds.width - t) / 2, y: 0, width: t, height: bounds.height)
        case .vertical: CGRect(x: 0, y: (bounds.height - t) / 2, width: bounds.width, height: t)
        }
    }

    /// The line's color as drawn now.
    var lineColor: CGColor? { line.backgroundColor }

    /// Set only by the owning screen's hover pass.
    func setHovered(_ hovered: Bool) { isHovered = hovered }

    override func mouseEntered(with event: NSEvent) { onPointerChange?() }
    override func mouseExited(with event: NSEvent) { onPointerChange?() }

    /// Leaving the view tree mid-drag: the mouse-up will never arrive here,
    /// so the drag state ends with the view (the screen ends the gesture).
    override func viewWillMove(toSuperview newSuperview: NSView?) {
        super.viewWillMove(toSuperview: newSuperview)
        if newSuperview == nil {
            isDragging = false
            isHovered = false
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

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
        let isEdge = isColumnEdge
        performWithTheme {
            let active = (isHovered || isDragging) && showsActiveLine
            let color: NSColor
            if isEdge {
                color = active ? Palette.focusRing.withAlphaComponent(0.45) : .clear
            } else {
                color = active ? Palette.focusRing.withAlphaComponent(0.6) : ((showsIdleLine || Palette.surfaceOverride(.splitDivider) != nil) ? (Palette.surfaceOverride(.splitDivider) ?? Palette.separator) : .clear)
            }
            Motion.transaction(.hover) {
                line.backgroundColor = color.cgColor
                line.cornerRadius = isEdge ? 1 : 0
            }
        }
    }
}

extension DividerHandleView.Kind {
    /// Id of this divider's `LayoutMouseArea`.
    var mouseAreaID: String {
        switch self {
        case .split(let id): "split:\(id.rawValue)"
        case .columnEdge(let id): "column:\(id.rawValue)"
        case .rowEdge(_, let row): "row:\(row.rawValue)"
        }
    }
}
