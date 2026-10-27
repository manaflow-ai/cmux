import AppKit
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextIcons
import CmuxNextInput

/// One extension action: Chromium's icon, which already carries the badge
/// and the disabled look laid out on the whole button, with gray hover
/// and press fills.
final class ExtensionActionButton: NSButton, PointerHoverReporting {
    let actionID: String
    var onRun: (() -> Void)?
    var onMenu: ((CGPoint) -> Void)?
    /// Drag to reorder (pinned order): whether a drag may start, then the
    /// horizontal offset while dragging and when released (0 when the button
    /// leaves its window mid-drag).
    var canDrag: (() -> Bool)?
    var onDragMoved: ((CGFloat) -> Void)?
    var onDragEnded: ((CGFloat) -> Void)?

    private let density = DensityBinding()
    /// The action last shown (`update`).
    private var shown: CEFExtensionAction?
    /// Where the pointer is now (`OmnibarPointer`).
    private var hover: PointerHover?
    private var isHovering: Bool { hover?.isHovering ?? false }
    var isPointerHovering: Bool { isHovering }

    init(actionID: String) {
        self.actionID = actionID
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyUpOrDown
        wantsLayer = true
        target = self
        action = #selector(run)
        setAccessibilityIdentifier(ExtensionActionToolbar.Identifier.action(actionID))
        // The toolbar's button size (BrowserToolbarLayout counts on it), a fixed square: frame layout
        // reads `intrinsicContentSize`, the toolbar's stack view keeps it exactly.
        for orientation in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            setContentHuggingPriority(.required, for: orientation)
            setContentCompressionResistancePriority(.required, for: orientation)
        }
        density.update { [weak self] in
            guard let self else { return }
            if side != OmnibarStyle.buttonSize { side = OmnibarStyle.buttonSize; invalidateIntrinsicContentSize() }
            layer?.cornerRadius = OmnibarStyle.buttonCornerRadius
            // The icon is sized for the density.
            if let shown { applyIcon(shown) }
            needsLayout = true
        }
        density.start(in: self)
        hover = PointerHover(self) { [weak self] _ in self?.updateFill(animated: true) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The toolbar's button size, read in the density binding so a density change applies.
    private var side: CGFloat = 0
    override var intrinsicContentSize: NSSize { NSSize(width: side, height: side) }

    func update(_ action: CEFExtensionAction) {
        // Every store change renders every button: decode only an icon that changed.
        guard action != shown else { return }
        let iconChanged = action.iconPNG != shown?.iconPNG || image == nil
        shown = action
        if iconChanged { applyIcon(action) }
        themedToolTip = action.title.isEmpty ? action.name : action.title
        setAccessibilityLabel(action.name)
        // The badge is in the icon; VoiceOver reads it as the value.
        setAccessibilityValue(action.badge.isEmpty ? nil : action.badge)
        isEnabled = action.isEnabled
    }

    private func applyIcon(_ action: CEFExtensionAction) {
        // The extension's own image keeps its size (the bar's height) in the larger button.
        let size = OmnibarStyle.barHeight
        if let data = action.iconPNG, let icon = blockingNSImage(data) {
            icon.size = NSSize(width: size, height: size)
            image = icon
        } else {
            let icon = NSImage.icon(.browserToolbarExtensions, size: OmnibarStyle.toolbarIconSize)
            icon.accessibilityDescription = action.name
            image = icon
        }
    }

    @objc private func run() { onRun?() }

    /// The press under way: where it began and whether it became a reorder drag.
    private struct Press {
        let start: NSPoint
        var dragging = false
    }

    /// Set from the press's mouse-down to its mouse-up; AppKit sends both, and every drag between,
    /// to this view.
    private var press: Press?

    /// The horizontal travel past which a press may become a reorder drag.
    static let dragThreshold: CGFloat = 3

    /// A reorder drag's moves, once per frame on the window's drag frames (`pointerFrameDrags`); the drag's
    /// start past ``dragThreshold`` acts on its own event.
    private(set) lazy var dragMoves = PointerFrameDrag(owner: "ExtensionActionButton.drag", view: self) { [weak self] point in
        guard let self, let press = self.press, press.dragging else { return }
        onDragMoved?(point.x - press.start.x)
    }

    /// A click runs the action; a horizontal drag past ``dragThreshold`` reorders the pinned buttons.
    /// The press ends in `mouseUp(with:)`; no modal loop holds the run loop (Chromium's
    /// `views::Button` presses in OnMousePressed and clicks in OnMouseReleased, ui/views/controls/button/button.cc).
    override func mouseDown(with event: NSEvent) {
        guard isEnabled, window != nil else { return super.mouseDown(with: event) }
        press = Press(start: event.locationInWindow)
        dragMoves.began()
        isHighlighted = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard var press else { return super.mouseDragged(with: event) }
        if press.dragging { return dragMoves.dragged(event) }
        let dx = event.locationInWindow.x - press.start.x
        guard abs(dx) > Self.dragThreshold, canDrag?() == true else { return }
        press.dragging = true
        isHighlighted = false
        self.press = press
        onDragMoved?(dx)
    }

    override func mouseUp(with event: NSEvent) {
        dragMoves.ended() // the frame's pending offset lands before the drop
        guard let press else { return super.mouseUp(with: event) }
        self.press = nil
        isHighlighted = false
        if press.dragging {
            onDragEnded?(event.locationInWindow.x - press.start.x)
        } else if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onRun?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let window else { return }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        onMenu?(point)
    }

    override var isHighlighted: Bool { didSet { updateFill() } }

    /// Pressed while this action's context menu is open; when it closes the hover is read again
    /// (the menu tracked the mouse, so no exit event arrived).
    var isMenuOpen = false {
        didSet {
            guard isMenuOpen != oldValue else { return }
            if !isMenuOpen { hover?.refresh() }
            updateFill()
        }
    }

    // visibility-walk-allow: hover is a hit test: a view hidden or shown under a still pointer gets no exit or enter, so PointerHover reads the pointer again (input state, no view work)
    override func viewDidHide() {
        super.viewDidHide()
        hover?.refresh()
    }

    // visibility-walk-allow: hover is a hit test: a view hidden or shown under a still pointer gets no exit or enter, so PointerHover reads the pointer again (input state, no view work)
    override func viewDidUnhide() {
        super.viewDidUnhide()
        hover?.refresh()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Out of the window, the press's mouse-up never comes here: end the press. A reorder drag
        // ends at offset 0, its start index, so the toolbar clears the shifts and moves nothing.
        if window == nil, let press {
            dragMoves.cancel()
            self.press = nil
            isHighlighted = false
            if press.dragging { onDragEnded?(0) }
        }
        hover?.refresh()
    }

    // visibility-walk-allow: the hover fill is one layer color store in the theme scope, no layout or text measure; cheaper than a deferral
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateFill()
    }

    private func updateFill(animated: Bool = false) {
        performWithTheme {
            let color: NSColor = isHighlighted || isMenuOpen ? Palette.selectionFill : (isHovering && DesignSettings.shared.showsHoverFills ? Palette.hoverFill : .clear)
            if let layer { ChromeHover.paint(layer, color, animated: animated && window != nil, pressed: isHighlighted) }
        }
    }
}
