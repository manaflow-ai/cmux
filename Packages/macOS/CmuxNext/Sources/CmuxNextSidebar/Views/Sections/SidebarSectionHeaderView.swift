import AppKit
import CmuxNextDesign
import CmuxNextIcons
import CmuxNextInput

/// The title row of a titled pinned section. A click collapses or expands
/// it; the chevron shows on hover and while collapsed.
final class SidebarSectionHeaderView: NSView {
    var onPress: (() -> Void)?
    var onContextMenu: ((NSEvent, NSView) -> Void)?

    private let name = ChromeLabel(labelWithString: "")
    let chevron = DecorativeImageView() // AXExpanded says what it draws
    private var collapsed = false
    /// Set by the hover owner (`PointerHover`, cx-3wu5).
    var isHovered = false { didSet { if isHovered != oldValue { updateChevron(); needsDisplay = true } } }
    private var pointerHover: PointerHover?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay // updateLayer sets colors only
        name.lineBreakMode = .byTruncatingTail
        name.maximumNumberOfLines = 1
        chevron.alphaValue = 0
        [name, chevron].forEach(addSubview)
        setAccessibilityElement(true)
        setAccessibilityRole(.disclosureTriangle)
        pointerHover = PointerHover(self) { [weak self] hovering in self?.isHovered = hovering }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// A drag from a press to a point (window points): true once the region drags.
    var onDragged: ((NSPoint, NSPoint) -> Bool)?
    var onDragEnded: (() -> Void)?
    private var pressLocation: NSPoint?
    private var didDrag = false
    /// The running drag's moves, once per frame on the window's drag frames (the press past the threshold acts at once).
    private(set) lazy var dragMoves = PointerFrameDrag(owner: "SidebarSectionHeaderView.drag", view: self) { [weak self] point in
        guard let self, let start = self.pressLocation else { return }
        _ = onDragged?(start, point)
    }

    nonisolated override var isFlipped: Bool { true }
    nonisolated override var wantsUpdateLayer: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func configure(title: String, collapsed: Bool) {
        name.stringValue = title
        self.collapsed = collapsed
        setAccessibilityLabel(title)
        setAccessibilityExpanded(!collapsed)
        setAccessibilityHelp(collapsed ? SectionStrings.expand : SectionStrings.collapse)
        updateChevron()
        needsLayout = true
    }

    private func updateChevron() {
        chevron.image = SidebarStyle.chevron(collapsed: collapsed)
        // Fades in place: the chevron stays mounted (stability rule).
        let alpha: CGFloat = collapsed || isHovered ? 1 : 0
        guard chevron.alphaValue != alpha else { return }
        guard window != nil, Motion.canAnimate(in: self) else { chevron.alphaValue = alpha; return }
        Motion.feedback.animate(.hover, in: self) { chevron.animator().alphaValue = alpha }
    }

    override func updateLayer() {
        performWithTheme {
            name.textColor = Palette.textTertiary
            chevron.contentTintColor = Palette.textTertiary
            // A click folds the section: hover shows the row hover fill (cx-qno.17).
            if let layer {
                layer.cornerRadius = SidebarStyle.rowCornerRadius
                ChromeHover.paint(layer, isHovered ? Palette.hoverFill : nil, animated: window != nil)
            }
        }
    }

    override func layout() {
        super.layout()
        let b = bounds
        let inset = SidebarStyle.horizontalInset * 2
        name.font = SidebarStyle.headerFont
        let th = ceil(name.intrinsicContentSize.height)
        let chevronSide = Metrics.smallIconSize
        chevron.frame = NSRect(x: b.width - inset - chevronSide, y: (b.height - chevronSide) / 2, width: chevronSide, height: chevronSide)
        // The label cell draws inside its frame: the text starts at the inset, with workspace titles.
        let nameX = inset - SidebarStyle.labelCellPadding
        name.frame = NSRect(x: nameX, y: (b.height - th) / 2, width: max(0, chevron.frame.minX - Metrics.space2 - nameX), height: th)
    }

    // visibility-walk-allow: only invalidates; AppKit draws a hidden view when it shows, so the repaint already waits for it
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// A click toggles on release; a drag moves the section (R77).
    override func mouseDown(with event: NSEvent) {
        pressLocation = event.locationInWindow
        didDrag = false
        dragMoves.began()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressLocation else { return }
        if didDrag { return dragMoves.dragged(event) }
        guard onDragged?(pressLocation, event.locationInWindow) == true else { return }
        didDrag = true
    }

    override func mouseUp(with event: NSEvent) {
        dragMoves.ended() // the frame's pending point lands before the drop
        defer { pressLocation = nil; didDrag = false }
        guard pressLocation != nil else { return }
        if didDrag { onDragEnded?() } else { onPress?() }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let onContextMenu else { return super.rightMouseDown(with: event) }
        onContextMenu(event, self)
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
}
