import AppKit
import CmuxNextDesign

/// The grab strip on the right sidebar's edge facing the content: a drag
/// resizes the sidebar. Invisible at rest; a hairline fades in while the
/// pointer is over it or it drags, so the edge is not a seam at rest.
final class RightSidebarResizeHandle: NSView {
    /// A drag's steps: its start, the pointer's distance from where it began, its end.
    enum Phase {
        case began
        case changed(CGFloat)
        case ended
    }

    /// The strip's width: the grab area, inside the sidebar.
    static let grabWidth: CGFloat = 6

    var onDrag: ((Phase) -> Void)?
    /// The sidebar edge the strip sits on (`.minX` beside content on its left, `.maxX` on its right).
    var edge: NSRectEdge = .minX { didSet { if edge != oldValue { needsLayout = true } } }
    private var isDragging = false { didSet { updateLine() } }
    private var isHovered = false { didSet { updateLine() } }
    private var hover: PointerHover?
    private var startX: CGFloat = 0
    private let line = CALayer()
    /// The accent band on the edge while hovered or dragged (`DividerGlowBand`).
    let glow = DividerGlowBand()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        line.opacity = 0
        layer?.addSublayer(line)
        layer?.addSublayer(glow.layer)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel(RightSidebarStrings.resize)
        setAccessibilityIdentifier("cmux.rightSidebar.resize")
        hover = PointerHover(self) { [weak self] hovering in self?.isHovered = hovering }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

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
        let width = Metrics.lineWidth(Metrics.dividerThickness)
        let x = edge == .minX ? 0 : bounds.width - width
        line.frame = CGRect(x: x, y: 0, width: width, height: bounds.height)
        CATransaction.commit()
        // The band's core sits just inside the edge, so the strip's own bounds hold it.
        let core = DividerGlowBand.coreThickness
        glow.place(along: CGRect(x: edge == .minX ? 0 : bounds.width - core, y: 0, width: core, height: bounds.height), vertical: true)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyLineTheme()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyLineTheme()
    }

    /// Hidden with the sidebar under a still pointer: no exit comes.
    override func viewDidHide() {
        super.viewDidHide()
        hover?.refresh()
    }

    /// Removed mid-drag: the release never arrives here, so the drag (and its band) ends now.
    override func viewWillMove(toSuperview newSuperview: NSView?) {
        super.viewWillMove(toSuperview: newSuperview)
        if newSuperview == nil { isDragging = false }
    }

    private func applyLineTheme() {
        performWithTheme { line.backgroundColor = Palette.separator.cgColor }
        glow.applyTheme(self)
        needsLayout = true
    }

    private func updateLine() {
        glow.set(isDragging ? .dragging : isHovered ? .hovered : .rest)
        let target: Float = isHovered || isDragging ? 1 : 0
        guard line.opacity != target else { return }
        Motion.sidebar.set(line, "opacity", to: target, fade: .hover)
    }

    /// A press here resizes, also in the titlebar band: it never moves the window.
    override var mouseDownCanMoveWindow: Bool { false }

    /// The press that takes key back from a focused page starts the drag.
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

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        isDragging = false
        onDrag?(.ended)
    }
}
