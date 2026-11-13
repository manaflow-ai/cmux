import AppKit
import CmuxNextDesign

/// Small square icon button (close, back) with gray hover.
final class PageInfoIconButton: NSButton {
    private let handler: () -> Void
    private var tracking: NSTrackingArea?

    init(symbol: String, label: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        focusRingType = .none
        image = PageInfoStyle.symbol(symbol, size: PageInfoStyle.iconSize - 2)
        setAccessibilityLabel(label)
        wantsLayer = true
        layer?.cornerRadius = PageInfoStyle.itemCornerRadius
        target = self
        action = #selector(press)
        let side = PageInfoStyle.rowHeight - 4
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: side), heightAnchor.constraint(equalToConstant: side)])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func press() { handler() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    private var isHovering = false { didSet { applyColors() } }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColors()
    }

    private func applyColors() {
        performWithTheme {
            layer?.backgroundColor = (isHovering ? PageInfoStyle.hover : .clear).cgColor
            contentTintColor = PageInfoStyle.secondaryText
        }
    }
}
