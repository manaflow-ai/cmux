import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// One extension action: Chromium's icon, which already carries the badge
/// and the disabled look laid out on the whole button, with gray hover
/// and press fills.
final class ExtensionActionButton: ClickableButton, PointerHoverReporting {
    let actionID: String
    var onRun: (() -> Void)?
    var onMenu: ((CGPoint) -> Void)?
    /// Drag to reorder (pinned order): whether a drag may start, then the
    /// horizontal offset while dragging and when released.
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
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyUpOrDown
        wantsLayer = true
        target = self
        action = #selector(run)
        setAccessibilityIdentifier(ExtensionActionToolbar.Identifier.action(actionID))
        // The toolbar's button size (BrowserToolbarLayout counts on it).
        NSLayoutConstraint.activate([
            density.bind(widthAnchor.constraint(equalToConstant: 0)) { OmnibarStyle.buttonSize },
            density.bind(heightAnchor.constraint(equalToConstant: 0)) { OmnibarStyle.buttonSize },
        ])
        density.update { [weak self] in
            guard let self else { return }
            layer?.cornerRadius = OmnibarStyle.buttonCornerRadius
            // The icon is sized for the density.
            if let shown { applyIcon(shown) }
            needsLayout = true
        }
        density.start()
        hover = PointerHover(self) { [weak self] _ in self?.updateFill(animated: true) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

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
        // The extension's own image fills the button (28 pt at Standard).
        let size = OmnibarStyle.buttonSize
        if let data = action.iconPNG, let icon = NSImage(data: data) {
            icon.size = NSSize(width: size, height: size)
            image = icon
        } else {
            let icon = NSImage.icon(.browserToolbarExtensions, size: OmnibarStyle.toolbarIconSize)
            icon.accessibilityDescription = action.name
            image = icon
        }
    }

    @objc private func run() { onRun?() }

    /// A click runs the action; a horizontal drag past 3 pt reorders the
    /// pinned buttons.
    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let window else { return super.mouseDown(with: event) }
        let start = event.locationInWindow
        var dragging = false
        isHighlighted = true
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let dx = next.locationInWindow.x - start.x
            if next.type == .leftMouseUp {
                isHighlighted = false
                if dragging {
                    onDragEnded?(dx)
                } else if bounds.contains(convert(next.locationInWindow, from: nil)) {
                    onRun?()
                }
                return
            }
            if !dragging, abs(dx) > 3, canDrag?() == true {
                dragging = true
                isHighlighted = false
            }
            if dragging { onDragMoved?(dx) }
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

    override func viewDidHide() {
        super.viewDidHide()
        hover?.refresh()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        hover?.refresh()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hover?.refresh()
    }

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
