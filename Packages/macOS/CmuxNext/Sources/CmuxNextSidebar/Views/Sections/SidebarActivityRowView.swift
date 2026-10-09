import AppKit
import CmuxNextDesign

/// A Priority or day header (or the empty message): small, muted, semibold.
final class SidebarActivityHeaderView: NSView {
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ text: String, isHeader: Bool) {
        label.stringValue = text
        label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: isHeader ? .semibold : .regular)
        performWithTheme { label.textColor = Palette.textSecondary }
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(text)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let height = label.intrinsicContentSize.height
        let x = SidebarStyle.horizontalInset * 2
        label.frame = NSRect(x: x, y: (bounds.height - height) / 2, width: max(0, bounds.width - x - Metrics.space2), height: height)
    }
}

/// One chat: its title over a muted one-line preview, a blue dot at the
/// leading edge while it needs the person. Opens on release, like the
/// sidebar's other rows; the hover and press fills are the shared chrome fills.
final class SidebarActivityRowView: NSView {
    /// The preview line's extra height over a one-line row.
    static let previewHeight: CGFloat = 14
    static let dotSize: CGFloat = 6

    var onPress: (() -> Void)?
    var contextMenu: (() -> NSMenu?)?
    private(set) var chat: SidebarActivityChat?
    private let pill = CALayer()
    let dot = CALayer()
    let title = NSTextField(labelWithString: "")
    let preview = NSTextField(labelWithString: "")
    private var pointerHover: PointerHover?
    private var isHovered = false { didSet { if isHovered != oldValue { if !isHovered { isPressed = false }; repaint(animated: true) } } }
    private var isPressed = false { didSet { if isPressed != oldValue { repaint(animated: false) } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for decoration in [pill, dot] {
            decoration.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
            decoration.cornerCurve = .continuous
            layer?.addSublayer(decoration)
        }
        for label in [title, preview] {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            addSubview(label)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        pointerHover = PointerHover(self) { [weak self] hovering in self?.isHovered = hovering }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    func configure(_ chat: SidebarActivityChat) {
        self.chat = chat
        title.stringValue = chat.title
        title.font = Typography.body
        preview.stringValue = chat.preview ?? ""
        preview.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        preview.isHidden = chat.preview == nil
        dot.isHidden = chat.attention == nil
        setAccessibilityLabel(chat.title)
        setAccessibilityValue(chat.attention.map(SidebarActivityView.label))
        setAccessibilityHelp(chat.preview)
        needsLayout = true
        repaint(animated: false)
    }

    private func repaint(animated: Bool) {
        performWithTheme {
            ChromeHover.paint(pill, ChromeHover.fillColor(ChromeHover.State(hovering: isHovered, pressed: isPressed, selected: false)), animated: animated)
            dot.backgroundColor = Palette.highlight.cgColor
            title.textColor = Palette.textPrimary
            preview.textColor = Palette.textSecondary
        }
    }

    override func updateLayer() { repaint(animated: false) }

    override func layout() {
        super.layout()
        let b = bounds
        let inset = SidebarStyle.horizontalInset
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pill.frame = NSRect(x: inset, y: 0, width: max(0, b.width - inset * 2), height: b.height)
        pill.cornerRadius = SidebarStyle.rowCornerRadius
        // The dot sits in the inset before the text, so titles line up with or without it.
        let textX = inset * 2 + Self.dotSize + Metrics.space1
        let titleHeight = title.intrinsicContentSize.height
        let lineHeight = Metrics.sidebarRowHeight
        let titleY = preview.isHidden ? (b.height - titleHeight) / 2 : (lineHeight - titleHeight) / 2 + 2
        let width = max(0, b.width - textX - inset * 2)
        title.frame = NSRect(x: textX, y: titleY, width: width, height: titleHeight)
        let previewHeight = preview.intrinsicContentSize.height
        preview.frame = NSRect(x: textX, y: title.frame.maxY, width: width, height: previewHeight)
        dot.frame = NSRect(x: inset + (textX - inset - Self.dotSize) / 2, y: title.frame.midY - Self.dotSize / 2,
                           width: Self.dotSize, height: Self.dotSize)
        dot.cornerRadius = Self.dotSize / 2
        CATransaction.commit()
    }

    override func mouseDown(with event: NSEvent) { isPressed = true }

    override func mouseUp(with event: NSEvent) {
        guard isPressed else { return super.mouseUp(with: event) }
        isPressed = false
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onPress?()
    }

    override func menu(for event: NSEvent) -> NSMenu? { contextMenu?() }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
}
