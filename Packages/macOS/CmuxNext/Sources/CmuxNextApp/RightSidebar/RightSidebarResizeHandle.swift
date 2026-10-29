import AppKit
import CmuxNextDesign
import CmuxNextInput
import CmuxNextWakeups

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
    /// The windows' frame-aligned pointer input (feature `pointerFrameDrags`): a drag resizes on a
    /// frame interval's first event and once more at its frame, to the latest point, as Chromium
    /// delivers rAF-aligned moves (`third_party/blink/renderer/platform/widget/input/
    /// main_thread_event_queue.cc`). Nil: every drag event resizes at once.
    var pointerFrames: FrameInputCoalescers?
    /// This drag's consumer of its window's coalescer, from mouse-down to mouse-up.
    private var frameDrag: PointerFrameConsumer?
    /// The sidebar edge the strip sits on (`.minX` beside content on its left, `.maxX` on its right).
    var edge: NSRectEdge = .minX { didSet { if edge != oldValue { needsLayout = true } } }
    private var isDragging = false { didSet { updateLine() } }
    private var isHovered = false { didSet { updateLine() } }
    private var hover: PointerHover?
    private var startX: CGFloat = 0
    private let line = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        line.opacity = 0
        layer?.addSublayer(line)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel(RightSidebarStrings.resize)
        setAccessibilityIdentifier("cmux.rightSidebar.resize")
        hover = PointerHover(self) { [weak self] hovering in self?.isHovered = hovering }
        addCursorUpdateArea()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The resize cursor, set when the pointer enters (``addCursorUpdateArea(_:)``): no cursor rects
    /// for the window to rebuild while the sidebar's width follows a drag.
    override func cursorUpdate(with event: NSEvent) {
        if #available(macOS 15, *) { NSCursor.columnResize.set() } else { NSCursor.resizeLeftRight.set() }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let width = Metrics.lineWidth(Metrics.dividerThickness)
        let x = edge == .minX ? 0 : bounds.width - width
        line.frame = CGRect(x: x, y: 0, width: width, height: bounds.height)
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyLineTheme()
        guard window != nil else { return }
        needsLayout = true // invalidate: another window's scale sets the line's width.
    }

    // visibility-walk-allow: the body only sets the hairline layer's color (applyLineTheme: performWithTheme resolves the theme's appearance), R-appear's kept form
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyLineTheme()
    }

    // visibility-walk-allow: no hidden gate; a strip hidden under a still pointer gets no mouse exit, so its hover ends here
    /// Hidden with the sidebar under a still pointer: no exit comes.
    override func viewDidHide() {
        super.viewDidHide()
        hover?.refresh()
    }

    private func applyLineTheme() {
        // No layout: `layout()` places the line from the edge and scale, never from a color.
        performWithTheme { line.backgroundColor = Palette.separator.cgColor }
    }

    private func updateLine() {
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
        endFrameDrag()
        frameDrag = window.flatMap { pointerFrames?.coalescer(for: $0) }?.consumer(owner: "RightSidebarResizeHandle") { [weak self] input in
            self?.deliver(input)
        }
        onDrag?(.began)
    }

    // local-monitor-allow: the drag's events go through its window's FrameInputCoalescer (frameDrag) under pointerFrameDrags; with the feature off each event resizes at once, as before it
    override func mouseDragged(with event: NSEvent) { // perf-hot: 2ms resize-drag (every drag event)
        guard isDragging else { return }
        if let frameDrag {
            frameDrag.post(event)
        } else {
            onDrag?(.changed(event.locationInWindow.x - startX))
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        // The frame's pending resize lands before the release (Chromium's ShouldFlushQueue).
        frameDrag?.flush()
        endFrameDrag()
        isDragging = false
        onDrag?(.ended)
    }

    /// Leaving the window mid-drag: no mouse-up comes, so nothing it has pending may land later.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { endFrameDrag() }
    }

    /// One delivery of the frame-aligned drag: the width follows the latest point.
    private func deliver(_ input: PointerCoalescedInput) { // perf-hot: 2ms resize-drag (each leading or trailing delivery)
        guard isDragging else { return }
        onDrag?(.changed(input.latest.location.x - startX))
    }

    /// Drops this drag's consumer and anything it still has pending.
    private func endFrameDrag() {
        frameDrag?.cancel()
        frameDrag = nil
    }
}
