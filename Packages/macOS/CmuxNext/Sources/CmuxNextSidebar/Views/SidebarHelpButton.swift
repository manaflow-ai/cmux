import AppKit
import CmuxNextDesign

/// A footer button that opens the app-owned Help menu at the sidebar edge.
final class SidebarHelpButton: NSButton {
    var menuProvider: (() -> NSMenu?)?

    private let symbol = "questionmark.circle"
    private var hover = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        imagePosition = .imageOnly
        isBordered = false
        refusesFirstResponder = true
        setAccessibilityRole(.button)
        setAccessibilityLabel(Strings.help)
        toolTip = Strings.help
        wantsLayer = true
        updateImage()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func layout() {
        super.layout()
        updateImage()
    }

    override func updateLayer() {
        layer?.cornerRadius = Metrics.itemCornerRadius
        performWithTheme {
            contentTintColor = hover ? Palette.textPrimary : Palette.textSecondary
            layer?.backgroundColor = hover ? Palette.hoverFill.cgColor : nil
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        hover = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hover = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard let menu = menuProvider?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private func updateImage() {
        let config = NSImage.SymbolConfiguration(pointSize: Metrics.smallIconSize, weight: .medium)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: Strings.help)?.withSymbolConfiguration(config)
    }
}
