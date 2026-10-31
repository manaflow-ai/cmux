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

    /// Every pointer event carries the modifier keys held (resize-modifiers.md).
    enum DragEvent {
        case began(NSPoint, NSEvent.ModifierFlags)
        case moved(NSPoint, NSEvent.ModifierFlags)
        case ended(NSPoint, NSEvent.ModifierFlags)
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
    /// The screen's uncovered rect and this handle's scroll area window when it was last placed
    /// (`applyPresentation`): its hidden state and cursor clip follow from them and the frame, so
    /// equal ones skip the work.
    var placedClips: [CGRect?]?
    /// The pointer crossed this handle's tracking area. The screen that owns
    /// the handles decides hover from the pointer and the current frames
    /// (`ScreenContentView.refreshDividerHover`); the handle keeps no hover
    /// of its own, because a layout change can move it under a still pointer.
    var onPointerChange: (() -> Void)?

    private let line = CALayer()
    /// The accent band over the line while hovered or dragged (`DividerGlowBand`).
    let glow = DividerGlowBand()
    private(set) var isHovered = false { didSet { if isHovered != oldValue { applyColors() } } }
    private var isDragging = false { didSet { applyColors() } }
    private var trackingArea: NSTrackingArea?
    /// Escape and modifier keys while a drag runs: this handle is never first responder, so it
    /// would hear neither. Installed on the press, removed when the drag ends.
    private var keyMonitor: Any?

    init(kind: Kind, axis: SplitAxis) {
        self.kind = kind
        self.axis = axis
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(line)
        layer?.addSublayer(glow.layer)
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
        glow.place(along: lineFrame, vertical: axis == .horizontal)
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
        guard !rect.isEmpty else { return }
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
        // A lit band reaches past the line: the page must leave its halo uncovered too.
        convert(glow.isLit ? lineFrame.union(glow.extent) : lineFrame, to: superview)
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
        if glow.isLit { return true }
        // Use the presentation color while the hover fade is running. The
        // page must remain covered until the last visible native pixel fades.
        guard let color = (line.presentation() ?? line).backgroundColor else { return false }
        return color.alpha > 0.001 && line.opacity > 0.001
    }

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
            stopKeyMonitor()
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
        startKeyMonitor()
        onDrag?(.began(event.locationInWindow, event.modifierFlags))
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        onDrag?(.moved(event.locationInWindow, event.modifierFlags))
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        isDragging = false
        stopKeyMonitor()
        onDrag?(.ended(event.locationInWindow, event.modifierFlags))
    }

    override func flagsChanged(with event: NSEvent) {
        guard isDragging else { return super.flagsChanged(with: event) }
        onDrag?(.modifiersChanged(event.modifierFlags))
    }

    /// Escape mid-drag (the key monitor; tests call it directly).
    override func cancelOperation(_ sender: Any?) {
        guard isDragging else { return }
        isDragging = false
        stopKeyMonitor()
        onDrag?(.cancelled)
    }

    private func startKeyMonitor() {
        stopKeyMonitor()
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

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        glow.applyTheme(self)
        // A drag always lights the band, under `layout.paneSeparation` none too (the app's default
        // look): it is the drag's cue, not a separator. Hover lights it only where hover shows a line.
        glow.set(isDragging ? .dragging : isHovered && showsActiveLine ? .hovered : .rest)
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
