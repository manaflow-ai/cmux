import AppKit
import CmuxNextDesign

/// One extension action: icon, native badge, gray hover and press fills.
final class ExtensionActionButton: NSButton {
    let actionID: String
    var onRun: (() -> Void)?
    var onMenu: ((CGPoint) -> Void)?

    private let badge = ChromeTextLayer()
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
        imageScaling = .scaleProportionallyDown
        wantsLayer = true
        target = self
        action = #selector(run)
        badge.alignmentMode = .center
        badge.isHidden = true
        layer?.addSublayer(badge)
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
        let size = BrowserMetrics.glyphSize
        if let data = action.iconPNG, let icon = NSImage(data: data) {
            icon.size = NSSize(width: size, height: size)
            image = icon
        } else {
            image = NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: action.name)
        }
        toolTip = action.title.isEmpty ? action.name : action.title
        setAccessibilityLabel(action.name)
        isEnabled = action.isEnabled
        alphaValue = action.isEnabled ? 1 : 0.45
        badge.string = action.badge
        badge.isHidden = action.badge.isEmpty
        if let rgba = CEFExtensionAction.rgba(action.badgeColor) {
            badge.backgroundColor = CGColor(srgbRed: rgba.red, green: rgba.green, blue: rgba.blue, alpha: rgba.alpha)
        }
        let text = CEFExtensionAction.rgba(action.badgeTextColor) ?? (1, 1, 1, 1)
        badge.foregroundColor = CGColor(srgbRed: text.red, green: text.green, blue: text.blue, alpha: text.alpha)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let font = BrowserMetrics.captionFont
        let fontSize = font.pointSize * 0.8
        badge.font = font.withSize(fontSize)
        badge.contentsScale = window?.backingScaleFactor ?? 2
        let height = ceil(fontSize + 2)
        let width = max(height, ceil(badge.string.size(withAttributes: [.font: font.withSize(fontSize)]).width) + 4)
        badge.cornerRadius = height / 2
        badge.frame = CGRect(x: bounds.maxX - width, y: 0, width: width, height: height)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
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
