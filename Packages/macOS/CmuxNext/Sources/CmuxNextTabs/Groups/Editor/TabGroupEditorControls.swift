import AppKit
import CmuxNextDesign
import QuartzCore

/// One color swatch in the group editor.
final class TabGroupSwatchView: NSView {
    let color: GroupColor
    var isChosen = false { didSet { if oldValue != isChosen { updateColors() } } }
    var onPick: ((GroupColor) -> Void)?
    private let fill = CALayer()
    private let ring = CALayer()
    private var isHovered = false { didSet { if oldValue != isHovered { updateColors() } } }

    init(color: GroupColor) {
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        ring.borderWidth = Metrics.space1 * 0.75
        for sublayer in [ring, fill] {
            sublayer.actions = ["bounds": NSNull(), "position": NSNull(), "cornerRadius": NSNull()]
            layer?.addSublayer(sublayer)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(color.localizedName)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var intrinsicContentSize: NSSize {
        let side = Metrics.iconSize + Metrics.space2
        return NSSize(width: side, height: side)
    }

    override func layout() {
        super.layout()
        let side = min(bounds.width, bounds.height)
        let outer = CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
        ring.frame = outer
        ring.cornerRadius = side / 2
        let inner = outer.insetBy(dx: Metrics.space1 + 1, dy: Metrics.space1 + 1)
        fill.frame = inner
        fill.cornerRadius = inner.width / 2
        updateColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        performWithTheme {
            fill.backgroundColor = color.swatch.cgColor
            ring.borderColor = (isChosen ? Palette.textPrimary : (isHovered ? Palette.separator : NSColor.clear)).cgColor
        }
        setAccessibilityValue(isChosen ? 1 : 0)
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPick?(color) }
    }

    override func accessibilityPerformPress() -> Bool {
        onPick?(color)
        return true
    }
}

/// A menu-like row in the group editor.
final class TabGroupEditorRow: NSView {
    var onPress: (() -> Void)?
    private let label = NSTextField(labelWithString: "")
    private var isHovered = false { didSet { if oldValue != isHovered { updateColors() } } }

    init(title: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Metrics.itemCornerRadius
        layer?.cornerCurve = .continuous
        label.font = Typography.body
        label.stringValue = title
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Metrics.sidebarRowHeight),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.space4),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Metrics.space4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    var title: String {
        get { label.stringValue }
        set {
            label.stringValue = newValue
            setAccessibilityLabel(newValue)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        performWithTheme {
            layer?.backgroundColor = isHovered ? Palette.hoverFill.cgColor : nil
            label.textColor = Palette.textPrimary
        }
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
}
