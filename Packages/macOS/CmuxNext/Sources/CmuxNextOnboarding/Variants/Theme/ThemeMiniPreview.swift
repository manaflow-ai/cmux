import AppKit
import CmuxNextDesign

/// A small terminal in a theme's own colors: its background with a few
/// rows of short bars in its ANSI colors, like code at a glance. The
/// selection ring is Palette.textPrimary, concentric with the tile.
final class ThemeMiniPreview: ThemePressable {
    /// The tile's inset inside the ring and its radius.
    static let inset: CGFloat = 4
    static let radius: CGFloat = 10

    var input: ThemeInput = .ghosttyDefault { didSet { if input != oldValue { needsDisplay = true } } }
    var isSelected = false { didSet { if isSelected != oldValue { needsDisplay = true } } }

    // (ANSI index or nil for the foreground, fraction of the width).
    private static let rows: [[(Int?, CGFloat)]] = [
        [(4, 0.22), (5, 0.14), (nil, 0.30)],
        [(1, 0.18), (nil, 0.44)],
        [(4, 0.22), (2, 0.06), (nil, 0.26)],
        [(2, 0.06), (nil, 0.38)],
    ]

    override func draw(_ dirtyRect: NSRect) {
        let tile = bounds.insetBy(dx: Self.inset, dy: Self.inset)
        if isSelected {
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: Self.radius + Self.inset - 1,
                                    yRadius: Self.radius + Self.inset - 1)
            ring.lineWidth = 2
            Palette.textPrimary.setStroke()
            ring.stroke()
        }
        let shape = NSBezierPath(roundedRect: tile, xRadius: Self.radius, yRadius: Self.radius)
        input.background.nsColor.setFill()
        shape.fill()
        ThemeKit.edge(input).setStroke()
        let edge = NSBezierPath(roundedRect: tile.insetBy(dx: 0.5, dy: 0.5), xRadius: Self.radius - 0.5, yRadius: Self.radius - 0.5)
        edge.lineWidth = 1
        edge.stroke()
        let pad = max(8, (tile.width * 0.1).rounded())
        let usable = tile.width - 2 * pad
        let barHeight: CGFloat = tile.height >= 80 ? 5 : 4
        let pitch = (tile.height - 2 * pad - barHeight) / CGFloat(Self.rows.count - 1)
        for (row, segments) in Self.rows.enumerated() {
            var x = tile.minX + pad
            let y = tile.minY + pad + CGFloat(row) * pitch
            for (color, fraction) in segments {
                let width = max(barHeight, (usable * fraction).rounded())
                ThemeKit.color(input, color).setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: y, width: width, height: barHeight), xRadius: barHeight / 2, yRadius: barHeight / 2).fill()
                x += width + barHeight
            }
        }
    }
}

/// A mini preview with the theme's name under it.
final class ThemeTile: NSStackView, ThemeChoiceItem {
    private let preview = ThemeMiniPreview()
    private let caption = OnboardingLabel.make(font: OnboardingMetrics.captionFont, color: Palette.textSecondary, lines: 2)

    var onPress: (() -> Void)? {
        get { preview.onPress }
        set { preview.onPress = newValue }
    }

    init(size: NSSize) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        orientation = .vertical
        alignment = .centerX
        spacing = 4
        caption.alignment = .center
        // A fixed wrap width makes the caption's height unambiguous.
        caption.preferredMaxLayoutWidth = size.width
        // In a row of tiles with one- and two-line names, a short tile keeps
        // its own height (top aligned) instead of stretching.
        setHuggingPriority(.defaultHigh, for: .vertical)
        addArrangedSubview(preview)
        addArrangedSubview(caption)
        NSLayoutConstraint.activate([
            preview.widthAnchor.constraint(equalToConstant: size.width), preview.heightAnchor.constraint(equalToConstant: size.height),
            caption.widthAnchor.constraint(equalTo: preview.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ choice: ThemeChoice, selected: Bool) {
        preview.input = choice.input
        preview.isSelected = selected
        preview.needsDisplay = true
        preview.setAccessibilityLabel(ThemeKit.name(choice))
        preview.setAccessibilityValue(selected)
        caption.stringValue = ThemeKit.name(choice)
        caption.font = .systemFont(ofSize: 11, weight: selected ? .medium : .regular)
        caption.textColor = selected ? Palette.textPrimary : Palette.textSecondary
    }
}
