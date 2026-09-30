import AppKit
import CmuxNextDesign

/// One extension action: Chromium's icon, which already carries the badge
/// and the disabled look laid out on the whole button (as Chrome's toolbar
/// draws it), with gray hover and press fills.
final class ExtensionActionButton: NSButton {
    let actionID: String
    var onRun: (() -> Void)?
    var onMenu: ((CGPoint) -> Void)?

    private let density = DensityBinding()
    private var isHovering = false { didSet { updateFill() } }
    private var tracking: NSTrackingArea?

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
        density.update { [unowned self] in
            layer?.cornerRadius = OmnibarStyle.buttonCornerRadius
            needsLayout = true
        }
        density.start()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(_ action: CEFExtensionAction) {
        let size = OmnibarStyle.buttonSize
        if let data = action.iconPNG, let icon = NSImage(data: data) {
            icon.size = NSSize(width: size, height: size)
            image = icon
        } else {
            image = NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: action.name)
        }
        toolTip = action.title.isEmpty ? action.name : action.title
        setAccessibilityLabel(action.name)
        // The badge is in the icon; VoiceOver reads it as the value.
        setAccessibilityValue(action.badge.isEmpty ? nil : action.badge)
        isEnabled = action.isEnabled
    }

    @objc private func run() { onRun?() }

    override func rightMouseDown(with event: NSEvent) {
        guard let window else { return }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        onMenu?(point)
    }

    override var isHighlighted: Bool { didSet { updateFill() } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateFill()
    }

    private func updateFill() {
        let color: NSColor = isHighlighted ? Palette.selectionFill : (isHovering ? Palette.hoverFill : .clear)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = color.cgColor
        }
    }
}
