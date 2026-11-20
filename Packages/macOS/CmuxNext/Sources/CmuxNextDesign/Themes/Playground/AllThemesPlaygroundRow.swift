import AppKit
import CmuxNextDesignTokens

/// One theme in ``AllThemesPlaygroundView``: its name, mode and failing count in its foreground,
/// then each sample as a chip of its ground with its ink ("Aa" for text, a dot for a mark) and
/// the contrast; a failing chip is ringed red, and hovering a chip shows what it samples.
///
/// The row draws itself (one layer, no subviews per chip) from a value snapshot of its entry.
final class AllThemesPlaygroundRow: NSView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("cmux.allThemesPlayground.row")

    /// The row's side margin in the table, the list's padding.
    static let margin: CGFloat = 12
    /// The padding inside the row's rounded ground.
    static let padding: CGFloat = 8
    /// The name column's width.
    static let labelWidth: CGFloat = 170
    /// The space between the name column and the chips.
    static let gap: CGFloat = 10
    /// A chip's size.
    static let chip = NSSize(width: 44, height: 34)
    /// The space between chips, across and down.
    static let chipSpacing: CGFloat = 4

    /// The theme the row shows.
    var entry: AllThemesPlaygroundEntry? {
        didSet {
            guard entry != oldValue else { return }
            placeChips()
        }
    }

    /// The chip frames of the last layout, in the row's coordinates (top-left origin).
    private(set) var chipFrames: [NSRect] = []

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    // MARK: Layout

    /// The chips across one line in a row `width` wide.
    static func chipsPerLine(width: CGFloat) -> Int {
        let grid = width - 2 * margin - 2 * padding - labelWidth - gap
        return max(1, Int((grid + chipSpacing) / (chip.width + chipSpacing)))
    }

    /// The height of `entry`'s row in a table `width` wide: the taller of the name column and the
    /// chip grid, plus the padding.
    @MainActor static func height(of entry: AllThemesPlaygroundEntry, width: CGFloat) -> CGFloat {
        let perLine = chipsPerLine(width: width)
        let lines = (entry.samples.count + perLine - 1) / perLine
        let grid = lines == 0 ? 0 : CGFloat(lines) * chip.height + CGFloat(lines - 1) * chipSpacing
        return max(labelHeight, grid) + 2 * padding
    }

    /// The name column's height: the name and two caption lines, two points apart.
    @MainActor private static var labelHeight: CGFloat {
        lineHeight(nameFont) + 2 * lineHeight(captionFont) + 4
    }

    @MainActor private static var nameFont: NSFont { Typography.system(size: TypeScale.body, weight: .semibold) }
    @MainActor private static var captionFont: NSFont { Typography.system(size: TypeScale.caption) }
    @MainActor private static var contrastFont: NSFont { Typography.system(.monospacedDigit, size: TypeScale.caption) }
    @MainActor private static var sampleFont: NSFont { Typography.system(size: TypeScale.body) }

    private static func lineHeight(_ font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let rewraps = newSize.width != frame.width
        super.setFrameSize(newSize)
        if rewraps { placeChips() }
    }

    /// Places the chips for the row's width and points each chip's tooltip at its sample.
    private func placeChips() {
        needsDisplay = true
        guard let entry else {
            chipFrames = []
            setThemedToolTipRegions([])
            return
        }
        let perLine = Self.chipsPerLine(width: bounds.width)
        let originX = Self.margin + Self.padding + Self.labelWidth + Self.gap
        chipFrames = entry.samples.indices.map { index in
            let column = index % perLine
            let line = index / perLine
            return NSRect(x: originX + CGFloat(column) * (Self.chip.width + Self.chipSpacing),
                          y: Self.padding + CGFloat(line) * (Self.chip.height + Self.chipSpacing),
                          width: Self.chip.width, height: Self.chip.height)
        }
        setThemedToolTipRegions(zip(chipFrames, entry.samples).map { ($0, AllThemesPlaygroundStrings.sampleHelp($1)) })
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let entry else { return }
        let ground = NSRect(x: Self.margin, y: 0, width: max(0, bounds.width - 2 * Self.margin), height: bounds.height)
        entry.background.withAlpha(1).nsColor.setFill()
        NSBezierPath(roundedRect: ground, xRadius: Metrics.surfaceCornerRadius, yRadius: Metrics.surfaceCornerRadius).fill()
        drawLabels(entry, in: ground)
        for (frame, sample) in zip(chipFrames, entry.samples) where frame.intersects(dirtyRect) {
            drawChip(sample, in: frame)
        }
    }

    private func drawLabels(_ entry: AllThemesPlaygroundEntry, in ground: NSRect) {
        let ink = entry.foreground.withAlpha(1).nsColor
        var y = Self.padding
        let x = ground.minX + Self.padding
        let lines: [(String, NSFont, CGFloat)] = [
            (entry.name, Self.nameFont, 1),
            (entry.isDark ? AllThemesPlaygroundStrings.dark : AllThemesPlaygroundStrings.light, Self.captionFont, 1),
            (AllThemesPlaygroundStrings.failing(entry.failures.count), Self.captionFont, entry.failures.isEmpty ? 0.6 : 1),
        ]
        for (text, font, alpha) in lines {
            let height = Self.lineHeight(font)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink.withAlphaComponent(alpha)]
            NSAttributedString(string: text, attributes: attributes)
                .draw(with: NSRect(x: x, y: y, width: Self.labelWidth, height: height),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            y += height + 2
        }
    }

    private func drawChip(_ sample: ThemeElementSample, in frame: NSRect) {
        let radius = Metrics.controlCornerRadius
        sample.surface.nsColor.setFill()
        NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius).fill()
        let ink = sample.ink.nsColor
        let contrast = NSAttributedString(string: String(format: "%.1f", sample.contrast),
                                          attributes: [.font: Self.contrastFont, .foregroundColor: ink])
        let contrastSize = contrast.size()
        let isText = sample.minimum >= ThemeTokens.minimumTextContrast
        let mark = NSAttributedString(string: "Aa", attributes: [.font: Self.sampleFont, .foregroundColor: ink])
        let markHeight = isText ? mark.size().height : 14
        // The mark over the contrast, one point apart, centered in the chip.
        var y = frame.midY - (markHeight + 1 + contrastSize.height) / 2
        if isText {
            let size = mark.size()
            mark.draw(at: NSPoint(x: frame.midX - size.width / 2, y: y))
        } else {
            ink.setFill()
            NSBezierPath(ovalIn: NSRect(x: frame.midX - 4, y: y + 3, width: 8, height: 8)).fill()
        }
        y += markHeight + 1
        contrast.draw(at: NSPoint(x: frame.midX - contrastSize.width / 2, y: y))
        guard !sample.passes else { return }
        StatusDotHue.error.hue(isDark: false).nsColor.setStroke()
        let ring = NSBezierPath(roundedRect: frame.insetBy(dx: 1, dy: 1), xRadius: radius - 1, yRadius: radius - 1)
        ring.lineWidth = 2
        ring.stroke()
    }
}
