import AppKit
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextIcons
import CmuxNextWakeups

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
    /// The app's decoded action icons, shared by every tab's toolbar.
    private let icons: ExtensionActionIcons
    /// The PNG on its way (`icons`): a later icon drops an earlier one's arrival.
    private var decoding: Data?
    /// The action's decoded icon, unsized.
    private var decodedIcon: CGImage?

    init(actionID: String, icons: ExtensionActionIcons) {
        self.actionID = actionID
        self.icons = icons
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
            if shown != nil { showIcon() }
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
        if iconChanged { loadIcon(action.iconPNG) }
        themedToolTip = action.title.isEmpty ? action.name : action.title
        setAccessibilityLabel(action.name)
        // The badge is in the icon; VoiceOver reads it as the value.
        setAccessibilityValue(action.badge.isEmpty ? nil : action.badge)
        isEnabled = action.isEnabled
    }

    /// Shows `png`'s icon: at once when any toolbar decoded it already, else the extension's last decoded icon (the
    /// puzzle piece before the first one) until it decodes off the main thread (``ExtensionActionIcons``).
    private func loadIcon(_ png: Data?) {
        guard let png else {
            (decoding, decodedIcon) = (nil, nil)
            showIcon()
            return
        }
        if let icon = icons.icon(id: actionID, png: png) {
            (decoding, decodedIcon) = (nil, icon)
            showIcon()
            return
        }
        guard png != decoding else { return }
        decoding = png
        let before = decodedIcon
        if decodedIcon == nil { decodedIcon = icons.latest(id: actionID) }
        if image == nil || decodedIcon !== before { showIcon() }
        icons.decode(id: actionID, png: png) { [weak self] bitmap in self?.decoded(bitmap, from: png) }
    }

    private func decoded(_ bitmap: CGImage?, from png: Data) {
        guard png == decoding else { return }
        (decoding, decodedIcon) = (nil, bitmap)
        showIcon()
    }

    /// The decoded icon at the bar's height (its size in the larger button), else Chrome's puzzle
    /// piece. A density change only resizes it.
    private func showIcon() {
        if let decodedIcon {
            image = IconAssetDecode.image(decodedIcon, points: OmnibarStyle.barHeight)
        } else {
            let icon = NSImage.icon(.browserToolbarExtensions, size: OmnibarStyle.toolbarIconSize)
            icon.accessibilityDescription = shown?.name
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

    /// A click runs the action; a horizontal drag past ``dragThreshold`` reorders the pinned buttons.
    /// The press ends in `mouseUp(with:)`; no modal loop holds the run loop (Chromium's
    /// `views::Button` presses in OnMousePressed and clicks in OnMouseReleased, ui/views/controls/button/button.cc).
    override func mouseDown(with event: NSEvent) {
        guard isEnabled, window != nil else { return super.mouseDown(with: event) }
        press = Press(start: event.locationInWindow)
        isHighlighted = true
    }

    // local-monitor-allow: a drag is delivered unbuffered until its mouse-up (p06-scheduler.md section E, FrameInputCoalescer); each move only offsets the pinned buttons
    override func mouseDragged(with event: NSEvent) {
        guard var press else { return super.mouseDragged(with: event) }
        let dx = event.locationInWindow.x - press.start.x
        if !press.dragging, abs(dx) > Self.dragThreshold, canDrag?() == true {
            press.dragging = true
            isHighlighted = false
        }
        self.press = press
        if press.dragging { onDragMoved?(dx) }
    }

    override func mouseUp(with event: NSEvent) {
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
