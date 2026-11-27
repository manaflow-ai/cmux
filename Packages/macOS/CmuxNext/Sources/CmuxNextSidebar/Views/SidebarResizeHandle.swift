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
final class SidebarResizeHandle: NSView, KeyNeutralPressTarget {
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
    /// The wallpaper's rim light along the edge (`appearance.wallpaperLighting`, ``WallpaperRimLayer``).
    private lazy var wallpaperRim = WallpaperRimLayer(host: self)
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

    /// In a curved-card window, the top of the card: the root supplies this y coordinate after layout;
    /// flat styles leave it at zero. A resting border line (`sidebar.border`) runs the whole edge
    /// whatever it says (``updateLineFrame()``).
    var lineMinY: CGFloat = 0 {
        didSet {
            guard lineMinY != oldValue else { return }
            needsLayout = true
            updateLineFrame()
        }
    }

    /// The line's frame after layout, exposed for geometry tests without exposing its layer.
    var drawnLineFrame: CGRect { line.frame }

    /// The hairline shows at rest when the sidebar border is on, else only
    /// on hover or while dragging, and never as hover feedback beside the
    /// curved main pane: the card's edge is the seam there, and the glow
    /// (``glow``) marks the hover. The hit area and the resize cursor stay.
    var isLineVisible: Bool { restingLineWidth > 0 || ((isHovered || isDragging) && !Metrics.cardEdgeIsSidebarSeam) }

    /// The drawn width: the border's, else the divider hairline.
    var lineWidth: CGFloat { restingLineWidth > 0 ? restingLineWidth : Metrics.lineWidth(Metrics.dividerThickness) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        line.opacity = 0
        layer?.addSublayer(line)
        layer?.addSublayer(wallpaperRim)
        layer?.addSublayer(glow.layer)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel(Strings.resize)
        setAccessibilityIdentifier("cmux.sidebar.resize")
        pointerHover = PointerHover(self) { [weak self] hovering in self?.setHovered(hovering) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static var resizeCursor: NSCursor {
        if #available(macOS 15, *) { return .columnResize }
        return .resizeLeftRight
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: Self.resizeCursor)
    }

    override func layout() {
        super.layout()
        updateLineFrame()
    }

    private func updateLineFrame() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let width = lineWidth
        // `sidebar.border` on draws the whole edge under every style, beside the card too. Leo, 2026-11-12:
        // "you've slightly regressed the border thing, the border divider."
        let minY = restingLineWidth > 0 ? 0 : min(max(0, lineMinY), bounds.height)
        line.frame = CGRect(x: edgeOffset - width / 2, y: minY, width: width, height: bounds.height - minY)
        CATransaction.commit()
        // The glow runs the whole edge, also where the line keeps to the titlebar band beside the card.
        glow.place(along: CGRect(x: line.frame.minX, y: 0, width: width, height: bounds.height), vertical: true)
        wallpaperRim.place(CGRect(x: line.frame.minX, y: 0, width: max(1, width), height: bounds.height), cornerRadius: 0, lineWidth: max(1, width))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyLineTheme()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        ResizeBands.register(self) // the band has priority over any scroller's knob under it
        applyLineTheme()
    }

    /// The hairline's color and width both go through the border metric
    /// (`Palette.separator`, `Metrics.lineWidth`): a borders change repaints
    /// here, and the relayout picks up the width.
    private func applyLineTheme() {
        performWithTheme { line.backgroundColor = (Palette.surfaceOverride(.splitDivider) ?? Palette.chromeDivider).cgColor }
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
        // Hover and drag light it in every style, beside the curved main pane too. Leo, 2026-11-12:
        // "there's no more drag divider highlight".
        glow.set(isDragging ? .dragging : isHovered ? .hovered : .rest)
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
