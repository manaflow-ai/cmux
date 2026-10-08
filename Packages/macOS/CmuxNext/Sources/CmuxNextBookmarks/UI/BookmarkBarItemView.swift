import AppKit
import CmuxNextDesign

/// One bookmark or folder on the bar: icon and title, a gray hover fill,
/// no accent color. Clicks and drags are reported to the bar.
final class BookmarkBarItemView: NSView {
    let node: BookmarkNode
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var hovered = false
    private var pressed = false
    private var tracking: NSTrackingArea?
    var onClick: ((BookmarkBarItemView, NSEvent) -> Void)?
    var onDragStart: ((BookmarkBarItemView, NSEvent) -> Void)?
    var onContextMenu: ((BookmarkBarItemView) -> NSMenu?)?
    private var downEvent: NSEvent?

    static var maxWidth: CGFloat { Metrics.tabMaxWidth * 0.8 }

    init(node: BookmarkNode, image: NSImage?) {
        self.node = node
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        icon.image = image
        icon.imageScaling = .scaleProportionallyDown
        label.stringValue = node.displayTitle
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        addSubview(icon)
        addSubview(label)
        toolTip = node.url.map { "\(node.displayTitle)\n\($0.absoluteString)" } ?? node.displayTitle
        setAccessibilityElement(true)
        setAccessibilityRole(node.isFolder ? .menuButton : .button)
        setAccessibilityLabel(node.displayTitle)
        setAccessibilityIdentifier("cmux.bookmarks.bar.item")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Width the item wants: padding, icon, gap, title, capped.
    var preferredWidth: CGFloat {
        let iconSize = Metrics.smallIconSize
        let text = node.displayTitle.isEmpty ? 0 : ceil((node.displayTitle as NSString).size(withAttributes: [.font: Typography.body]).width)
        // NSTextField draws its text with a small inset on each side.
        let gap = text > 0 ? Metrics.space2 + Metrics.space2 : 0
        return min(Metrics.space4 * 2 + iconSize + gap + text, Self.maxWidth)
    }

    override func layout() {
        super.layout()
        let iconSize = Metrics.smallIconSize
        layer?.cornerRadius = Metrics.itemCornerRadius
        icon.frame = NSRect(x: Metrics.space4, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)
        label.font = Typography.body
        let labelX = icon.frame.maxX + Metrics.space2
        let height = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(x: labelX, y: (bounds.height - height) / 2, width: max(0, bounds.width - labelX - Metrics.space4), height: height)
        label.isHidden = node.displayTitle.isEmpty
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    private func setHovered(_ value: Bool) {
        hovered = value
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        downEvent = event
        pressed = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = downEvent else { return }
        let distance = hypot(event.locationInWindow.x - down.locationInWindow.x, event.locationInWindow.y - down.locationInWindow.y)
        guard distance > 4 else { return }
        downEvent = nil
        pressed = false
        needsDisplay = true
        onDragStart?(self, down)
    }

    override func mouseUp(with event: NSEvent) {
        pressed = false
        needsDisplay = true
        guard downEvent != nil else { return }
        downEvent = nil
        onClick?(self, event)
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return super.otherMouseUp(with: event) }
        onClick?(self, event)
    }

    override func menu(for event: NSEvent) -> NSMenu? { onContextMenu?(self) }

    override func accessibilityPerformPress() -> Bool {
        guard let event = NSApp.currentEvent else { return false }
        onClick?(self, event)
        return true
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        performWithTheme {
            let fill = pressed ? Palette.pressedFill : (hovered ? Palette.hoverFill : NSColor.clear)
            layer?.backgroundColor = fill.cgColor
            label.textColor = Palette.textPrimary
            icon.contentTintColor = Palette.textSecondary
        }
    }
}
