import AppKit
import CmuxNextDesign
import CmuxNextCompat

/// Strip on the sidebar's edge facing the content that resizes it. Invisible until
/// the pointer is over it; then a hairline fades in (and stays while
/// dragging), so the edge never shows as a seam at rest.
///
/// The strip is wider than the line and lies across the edge (`SidebarResizeBand`), so the
/// container mounts it in its superview: inside the container AppKit would clip the outer part
/// out of hit testing, cursor rects and hover (u2255).
final class SidebarResizeHandle: NSView {
    enum Phase {
        case began
        case changed(CGFloat)
        case ended
    }

    var onDrag: ((Phase) -> Void)?
    private(set) var isDragging = false { didSet { updateLine() } }
    /// Set by the hover owner (`PointerHover`, cx-3wu5).
    private(set) var isHovered = false { didSet { updateLine() } }
    private var pointerHover: PointerHover?
    private var startX: CGFloat = 0
    private let line = CALayer()
    /// The accent band on the edge while hovered or dragged (`DividerGlowBand`).
    let glow = DividerGlowBand()

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
        layer?.addSublayer(glow.layer)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel(Strings.resize)
        setAccessibilityIdentifier("cmux.sidebar.resize")
        pointerHover = PointerHover(self) { [weak self] hovering in self?.setHovered(hovering) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() {
        if #available(macOS 15, *) {
            addCursorRect(bounds, cursor: .columnResize)
        } else {
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let width = lineWidth
        line.frame = CGRect(x: edgeOffset - width / 2, y: 0, width: width, height: bounds.height)
        CATransaction.commit()
        glow.place(along: line.frame, vertical: true)
    }

    override func viewDidChangeEffectiveAppearance() {
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
        glow.applyTheme(self)
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
    override func viewDidHide() {
        super.viewDidHide()
        pointerHover?.refresh()
    }

    /// Removed mid-drag: the release never arrives here, so the drag (and its band) ends now.
    override func viewWillMove(toSuperview newSuperview: NSView?) {
        super.viewWillMove(toSuperview: newSuperview)
        if newSuperview == nil { isDragging = false }
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        pointerHover?.refresh()
    }

    private func updateLine() {
        // Hover lights it only where the hairline would show on hover: beside the curved main pane
        // the card's edge is the seam. A drag lights it everywhere.
        glow.set(isDragging ? .dragging : isHovered && !Metrics.mainPaneCurved ? .hovered : .rest)
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
        onDrag?(.began)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        onDrag?(.changed(event.locationInWindow.x - startX))
    }

    /// Ends the drag early (it hid the sidebar); later drag events for
    /// this press are ignored.
    func endDrag() {
        isDragging = false
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        isDragging = false
        onDrag?(.ended)
    }
}
