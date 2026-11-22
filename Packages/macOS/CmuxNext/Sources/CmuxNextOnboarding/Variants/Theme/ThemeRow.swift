import AppKit
import CmuxNextDesign

/// A theme as one drawn row: `tinted` fills it with the theme's background
/// and writes the name in its foreground with a few ANSI dots; `plain` is
/// a neutral row with a small swatch and a gray selection fill; `text` is
/// just the name, bold when picked.
final class ThemeRow: ThemePressable, ThemeChoiceItem {
    enum Style { case tinted, plain, text }

    private let style: Style
    private var choice = ThemeChoice(name: nil, input: .ghosttyDefault)
    private var selected = false

    init(style: Style, height: CGFloat) {
        self.style = style
        super.init(frame: .zero)
        heightAnchor.constraint(equalToConstant: height).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ choice: ThemeChoice, selected: Bool) {
        self.choice = choice
        self.selected = selected
        setAccessibilityLabel(ThemeKit.name(choice))
        setAccessibilityValue(selected)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        switch style {
        case .tinted: drawTinted()
        case .plain: drawPlain()
        case .text: drawText()
        }
    }

    private func drawTinted() {
        let input = choice.input
        let tile = bounds.insetBy(dx: 4, dy: 4)
        if selected {
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 13, yRadius: 13)
            ring.lineWidth = 2
            Palette.textPrimary.setStroke()
            ring.stroke()
        }
        input.background.nsColor.setFill()
        NSBezierPath(roundedRect: tile, xRadius: 10, yRadius: 10).fill()
        ThemeKit.edge(input).setStroke()
        NSBezierPath(roundedRect: tile.insetBy(dx: 0.5, dy: 0.5), xRadius: 9.5, yRadius: 9.5).stroke()
        let dot: CGFloat = 8
        var x = tile.maxX - 12 - dot
        for index in [6, 5, 4, 3, 2, 1] {
            ThemeKit.color(input, index).setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: tile.midY - dot / 2, width: dot, height: dot)).fill()
            x -= dot + 4
        }
        drawName(in: NSRect(x: tile.minX + 12, y: tile.minY, width: x - tile.minX - 12, height: tile.height),
                 font: .systemFont(ofSize: 13, weight: .medium), color: input.foreground.nsColor)
    }

    private func drawPlain() {
        if selected {
            Palette.selectionFill.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
        }
        let size: CGFloat = 16
        let swatch = NSRect(x: 10, y: bounds.midY - size / 2, width: size, height: size)
        // A disc split down the middle: the theme's background and foreground.
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(ovalIn: swatch).addClip()
        choice.input.background.nsColor.setFill()
        swatch.fill()
        choice.input.foreground.nsColor.setFill()
        NSRect(x: swatch.midX, y: swatch.minY, width: swatch.width / 2, height: swatch.height).fill()
        NSGraphicsContext.restoreGraphicsState()
        Palette.separator.setStroke()
        NSBezierPath(ovalIn: swatch.insetBy(dx: 0.5, dy: 0.5)).stroke()
        drawName(in: NSRect(x: swatch.maxX + 10, y: 0, width: bounds.width - swatch.maxX - 20, height: bounds.height),
                 font: .systemFont(ofSize: 13, weight: selected ? .medium : .regular), color: Palette.textPrimary)
    }

    private func drawText() {
        drawName(in: bounds.insetBy(dx: 8, dy: 0), font: .systemFont(ofSize: 15, weight: selected ? .semibold : .regular),
                 color: selected ? Palette.textPrimary : Palette.textTertiary, centered: true)
    }

    private func drawName(in rect: NSRect, font: NSFont, color: NSColor, centered: Bool = false) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = centered ? .center : .natural
        let text = NSAttributedString(string: ThemeKit.name(choice), attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
        let height = ceil(font.ascender - font.descender + font.leading)
        text.draw(with: NSRect(x: rect.minX, y: rect.midY - height / 2, width: max(0, rect.width), height: height),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

/// A round swatch: the theme's background with a dot of its foreground,
/// ringed in Palette.textPrimary when picked.
final class ThemeSwatchDot: ThemePressable, ThemeChoiceItem {
    private var choice = ThemeChoice(name: nil, input: .ghosttyDefault)
    private var selected = false

    init(diameter: CGFloat) {
        super.init(frame: .zero)
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: diameter), heightAnchor.constraint(equalToConstant: diameter)])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ choice: ThemeChoice, selected: Bool) {
        self.choice = choice
        self.selected = selected
        setAccessibilityLabel(ThemeKit.name(choice))
        setAccessibilityValue(selected)
        toolTip = ThemeKit.name(choice)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if selected {
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
            ring.lineWidth = 2
            Palette.textPrimary.setStroke()
            ring.stroke()
        }
        let disc = bounds.insetBy(dx: 5, dy: 5)
        choice.input.background.nsColor.setFill()
        NSBezierPath(ovalIn: disc).fill()
        ThemeKit.edge(choice.input).setStroke()
        NSBezierPath(ovalIn: disc.insetBy(dx: 0.5, dy: 0.5)).stroke()
        choice.input.foreground.nsColor.setFill()
        let dot = disc.width * 0.32
        NSBezierPath(ovalIn: NSRect(x: disc.midX - dot / 2, y: disc.midY - dot / 2, width: dot, height: dot)).fill()
    }
}

/// A system radio button as a theme choice.
final class ThemeRadioItem: NSView, ThemeChoiceItem {
    var onPress: (() -> Void)?
    private lazy var radio: NSButton = OnboardingControl.radio("", target: self, action: #selector(pressed))  // no IUO (crash program)

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(radio)
        NSLayoutConstraint.activate([
            radio.leadingAnchor.constraint(equalTo: leadingAnchor), radio.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            radio.topAnchor.constraint(equalTo: topAnchor), radio.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func pressed() { onPress?() }

    func show(_ choice: ThemeChoice, selected: Bool) {
        let title = ThemeKit.name(choice)
        if radio.title != title {
            radio.attributedTitle = NSAttributedString(string: title, attributes: [.font: OnboardingMetrics.bodyFont, .foregroundColor: Palette.textPrimary])
        }
        radio.state = selected ? .on : .off
    }
}
