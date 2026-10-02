import AppKit
import CmuxNextDesign
import QuartzCore

/// A rail icon button: secondary text color, primary with the hover fill,
/// the pressed fill while held. No fill otherwise.
final class WindowRailButton: NSButton {
    let item: WindowRailItem
    var onPress: (() -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }

    init(item: WindowRailItem, label: String) {
        self.item = item
        super.init(frame: .zero)
        let config = NSImage.SymbolConfiguration(pointSize: WindowRail.iconSize, weight: .regular)
        image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: label)?.withSymbolConfiguration(config)
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        isBordered = false
        setAccessibilityLabel(label)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        target = self
        action = #selector(pressed)
        refusesFirstResponder = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func pressed() { onPress?() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = Metrics.itemCornerRadius
        performWithTheme {
            contentTintColor = hovering || isHighlighted ? Palette.textPrimary : Palette.textSecondary
            let fill: NSColor? = isHighlighted ? Palette.pressedFill : hovering ? Palette.hoverFill : nil
            layer?.backgroundColor = fill?.cgColor
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
}
