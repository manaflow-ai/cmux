import AppKit
import CmuxNextDesign
import QuartzCore

/// One card of the stack: a small rounded panel with a title, a quiet
/// detail line, an optional progress bar and text buttons, and an x on
/// hover when dismissible. A peeking card (behind the front one) shows
/// only its panel. Ghostty-derived colors.
final class SidebarCardView: NSView {
    static let height: CGFloat = 46
    static let tallHeight: CGFloat = 66
    private static let radius: CGFloat = 8
    private static let pad: CGFloat = 10

    var onAction: ((SidebarCardAction) -> Void)?
    var card = SidebarCard(id: "", title: "") { didSet { if oldValue != card { render() } } }
    var isPeek = false { didSet { if oldValue != isPeek { render() } } }

    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let track = CALayer()
    private let bar = CALayer()
    private var buttons: [NSButton] = []
    private let close = SidebarIconButton(symbol: "xmark", pointSize: { 9 }, label: Strings.dismissCard)
    private var hovered = false

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Self.radius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.shadowOpacity = 1
        layer?.shadowRadius = 6
        layer?.shadowOffset = CGSize(width: 0, height: -1)
        for label in [title, detail] {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            addSubview(label)
        }
        title.font = Typography.bodyEmphasized
        detail.font = Typography.caption
        track.cornerRadius = 1.5
        bar.cornerRadius = 1.5
        layer?.addSublayer(track)
        layer?.addSublayer(bar)
        close.onPress = { [weak self] in self?.onAction?(.dismiss) }
        addSubview(close)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func render() {
        title.stringValue = card.title
        detail.stringValue = card.detail ?? ""
        for button in buttons { button.removeFromSuperview() }
        buttons = card.buttons.map { spec in
            let button = NSButton(title: spec.title, target: self, action: #selector(buttonPressed(_:)))
            button.isBordered = false
            button.font = Typography.caption
            button.identifier = NSUserInterfaceItemIdentifier(spec.id)
            button.refusesFirstResponder = true
            addSubview(button)
            return button
        }
        performWithTheme { applyColors() }
        let content = !isPeek
        for view in [title, detail] as [NSView] + buttons { view.isHidden = !content }
        detail.isHidden = !content || card.detail == nil
        track.isHidden = !content || card.progress == nil
        bar.isHidden = track.isHidden
        close.isHidden = !(content && card.dismissible && hovered)
        setAccessibilityLabel([card.title, card.detail].compactMap { $0 }.joined(separator: ", "))
        needsLayout = true
    }

    // theme-scoped: called only inside performWithTheme
    private func applyColors() {
        layer?.backgroundColor = Palette.elevatedBackground.cgColor
        layer?.borderColor = (Borders.drawsLines ? Palette.separator : .clear).cgColor
        layer?.shadowColor = Palette.shadow.withAlphaComponent(0.18).cgColor
        title.textColor = Palette.textPrimary
        detail.textColor = Palette.textSecondary
        track.backgroundColor = Palette.hoverFill.cgColor
        bar.backgroundColor = Palette.textSecondary.cgColor
        for button in buttons { button.contentTintColor = Palette.textPrimary }
    }

    override func layout() {
        super.layout()
        let b = bounds, pad = Self.pad
        let closeSize: CGFloat = 16
        close.frame = NSRect(x: b.width - pad / 2 - closeSize, y: pad / 2, width: closeSize, height: closeSize)
        let textWidth = max(0, b.width - 2 * pad - (card.dismissible ? closeSize : 0))
        let titleHeight = title.intrinsicContentSize.height
        title.frame = NSRect(x: pad, y: 7, width: textWidth, height: titleHeight)
        var y = title.frame.maxY
        if !detail.isHidden {
            let h = detail.intrinsicContentSize.height
            detail.frame = NSRect(x: pad, y: y, width: textWidth, height: h)
            y += h
        }
        if !track.isHidden {
            y += 5
            track.frame = CGRect(x: pad, y: y, width: b.width - 2 * pad, height: 3)
            bar.frame = CGRect(x: pad, y: y, width: (b.width - 2 * pad) * CGFloat(min(1, max(0.03, card.progress ?? 0))), height: 3)
            y += 3
        }
        var x = pad
        for button in buttons {
            let size = button.intrinsicContentSize
            button.frame = NSRect(x: x, y: y + 3, width: size.width, height: size.height)
            x += size.width + 12
        }
    }

    // MARK: Input

    @objc private func buttonPressed(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        onAction?(.button(id))
    }

    override func mouseUp(with event: NSEvent) {
        guard !isPeek, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onAction?(.open)
    }

    override func accessibilityPerformPress() -> Bool {
        onAction?(.open)
        return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        close.isHidden = !(card.dismissible && !isPeek)
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        close.isHidden = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        render()
    }
}
