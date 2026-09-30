import AppKit
import CmuxNextDesign
import QuartzCore

/// Small borderless icon button with a gray hover fill (no blue).
final class SidebarIconButton: NSButton {
    private var hovering = false { didSet { needsDisplay = true } }
    var onPress: (() -> Void)?

    private let symbol: String
    private let weight: NSFont.Weight
    private let label: String
    /// Point size read at layout time so density changes apply live.
    private let pointSize: () -> CGFloat
    private var renderedSize: CGFloat = 0

    init(symbol: String, pointSize: @escaping () -> CGFloat = { Metrics.smallIconSize }, weight: NSFont.Weight = .semibold, label: String) {
        self.symbol = symbol
        self.weight = weight
        self.label = label
        self.pointSize = pointSize
        super.init(frame: .zero)
        renderSymbol()
        imagePosition = .imageOnly
        isBordered = false
        contentTintColor = Palette.textSecondary
        setAccessibilityLabel(label)
        toolTip = label
        wantsLayer = true
        layer?.cornerCurve = .continuous
        target = self
        action = #selector(pressed)
        refusesFirstResponder = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func pressed() { onPress?() }

    private func renderSymbol() {
        let size = pointSize()
        guard size != renderedSize else { return }
        renderedSize = size
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?.withSymbolConfiguration(config)
    }

    override func layout() {
        super.layout()
        renderSymbol()
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = Metrics.itemCornerRadius
        layer?.backgroundColor = hovering ? resolvedCGColor(Palette.hoverFill) : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
}
