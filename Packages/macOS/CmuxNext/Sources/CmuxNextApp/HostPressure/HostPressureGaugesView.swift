import AppKit
import CmuxNextDesign
import CmuxNextHostPressure
import CmuxNextHostPressureTunables

/// The host's pressure gauges (RFD 0182 B10), one component for every pressure the verdict carries:
/// CPU, memory, and tokens, cache and Mac slots where acpmux has a reading. Rust computes each gauge
/// (cmux-host-budget `gauges.rs`: percent, level and its numbers); this only draws them, in one of
/// three design versions (`hostPressure.gauges`, off by default).
final class HostPressureGaugesView: NSStackView {
    init(gauges: [HostPressureGauge], style: HostPressureGaugeStyle, width: CGFloat) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = style == .compact ? Metrics.space1 : Metrics.space2
        setAccessibilityIdentifier("cmux.hostPressure.gauges")
        switch style {
        case .off: break
        case .bars, .meters:
            for gauge in gauges { addArrangedSubview(Self.row(gauge, segmented: style == .meters, width: width)) }
        case .compact:
            // Three chips a line: five gauges fit in two lines of the popover's width.
            for start in stride(from: 0, to: gauges.count, by: 3) {
                let line = NSStackView(views: gauges[start ..< min(start + 3, gauges.count)].map(Self.chip))
                line.spacing = Metrics.space1
                addArrangedSubview(line)
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The name, the bar and its percent on one line; the numbers behind it under the bar.
    private static func row(_ gauge: HostPressureGauge, segmented: Bool, width: CGFloat) -> NSView {
        let name = label(HostPressureStrings.gaugeName(gauge.kind), font: Typography.caption, ink: .secondary)
        let percent = label(percentText(gauge.percent), font: Typography.captionDigits, ink: .primary)
        percent.alignment = .right
        let bar = HostPressureGaugeBar(gauge: gauge, segments: segmented ? 10 : 0)
        let detail = label(gauge.detail, font: Typography.caption, ink: .tertiary)
        let grid = NSGridView(views: [[name, bar, percent], [NSView(), detail, NSView()]])
        grid.columnSpacing = Metrics.space2
        grid.rowSpacing = 0
        grid.rowAlignment = .none
        grid.row(at: 0).yPlacement = .center
        let nameWidth: CGFloat = 72, percentWidth: CGFloat = 44
        grid.column(at: 0).width = nameWidth
        grid.column(at: 2).width = percentWidth
        grid.column(at: 2).xPlacement = .trailing
        grid.column(at: 1).width = width - nameWidth - percentWidth - 2 * grid.columnSpacing
        grid.cell(atColumnIndex: 1, rowIndex: 1).xPlacement = .leading
        grid.setAccessibilityElement(true)
        grid.setAccessibilityLabel("\(HostPressureStrings.gaugeName(gauge.kind)) \(percentText(gauge.percent)), \(gauge.detail)")
        grid.setAccessibilityIdentifier("cmux.hostPressure.gauge.\(gauge.kind)")
        return grid
    }

    /// "CPU 80%": the name in secondary ink and the percent in its level's color.
    private static func chip(_ gauge: HostPressureGauge) -> NSView {
        let name = label(HostPressureStrings.gaugeName(gauge.kind), font: Typography.caption, ink: .secondary)
        let value = label(percentText(gauge.percent), font: Typography.captionDigits, ink: .primary)
        let level = gauge.level
        value.themeColor = { HostPressureGaugeBar.color(level) }
        let chip = HostPressureGaugeChip(views: [name, value])
        chip.themedToolTip = gauge.detail
        chip.setAccessibilityElement(true)
        chip.setAccessibilityLabel("\(HostPressureStrings.gaugeName(gauge.kind)) \(percentText(gauge.percent)), \(gauge.detail)")
        chip.setAccessibilityIdentifier("cmux.hostPressure.gauge.\(gauge.kind)")
        return chip
    }

    static func percentText(_ percent: Double) -> String {
        (percent / 100).formatted(.percent.precision(.fractionLength(0)))
    }

    private static func label(_ text: String, font: NSFont, ink: ThemeInk) -> ThemedLabel {
        let label = ThemedLabel(labelWithString: text)
        label.font = font
        label.ink = ink
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }
}

/// A gauge's track and fill (`segments` 0: one bar; else that many cells), in its level's color.
/// Colors are read in `updateLayer`, so a theme change repaints it.
final class HostPressureGaugeBar: NSView {
    static let height: CGFloat = 6
    private let fraction: CGFloat
    private let level: String
    private let segments: Int
    private let fills: [CALayer]

    init(gauge: HostPressureGauge, segments: Int) {
        fraction = CGFloat(min(max(gauge.percent / 100, 0), 1))
        level = gauge.level
        self.segments = segments
        fills = (0 ..< max(segments, 1) * 2).map { _ in CALayer() }
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        fills.forEach { layer?.addSublayer($0) }
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true
        setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    /// normal, warn, critical: the theme's success, attention and danger colors.
    @MainActor static func color(_ level: String) -> NSColor {
        switch level {
        case "critical": Palette.danger
        case "warn": Palette.attention
        default: Palette.success
        }
    }

    override func layout() {
        super.layout()
        needsDisplay = true
    }

    override func updateLayer() {
        let (track, fill) = performWithTheme { (Palette.groupFill.cgColor, Self.color(level).cgColor) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let radius = Self.height / 2
        if segments == 0 {
            // fills[0] the track, fills[1] the fill.
            fills[0].frame = bounds
            fills[1].frame = CGRect(x: 0, y: 0, width: (bounds.width * fraction).rounded(), height: bounds.height)
            for (index, layer) in fills.enumerated() {
                layer.cornerRadius = radius
                layer.backgroundColor = index == 0 ? track : fill
            }
            return
        }
        // Each cell: one track layer, and its fill layer drawn when the gauge reaches it.
        let gap: CGFloat = 2
        let cell = (bounds.width - gap * CGFloat(segments - 1)) / CGFloat(segments)
        let lit = Int((fraction * CGFloat(segments)).rounded(.up))
        for index in 0 ..< segments {
            let frame = CGRect(x: CGFloat(index) * (cell + gap), y: 0, width: max(cell, 0), height: bounds.height)
            let (back, front) = (fills[2 * index], fills[2 * index + 1])
            back.frame = frame
            front.frame = frame
            back.cornerRadius = 1.5
            front.cornerRadius = 1.5
            back.backgroundColor = track
            front.backgroundColor = index < lit ? fill : nil
        }
    }
}

/// A compact gauge: its name and percent on the theme's group fill.
final class HostPressureGaugeChip: NSStackView {
    override init(frame: NSRect) {
        super.init(frame: frame)
    }

    convenience init(views: [NSView]) {
        self.init(frame: .zero)
        setViews(views, in: .leading)
        spacing = Metrics.space1
        edgeInsets = NSEdgeInsets(top: 2, left: Metrics.space2, bottom: 2, right: Metrics.space2)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = bounds.height / 2
        layer?.backgroundColor = performWithTheme { Palette.groupFill.cgColor }
    }
}
