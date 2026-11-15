import AppKit
import CmuxNextDesign

/// The font picker's dock in the palette (``PaletteFontTuner``): the target strip, the sample drawn
/// in the highlighted family at the chosen size and line height, and the size and line height
/// sliders. Its height is fixed for a layout (``height(for:)``), so switching targets, moving the
/// highlight or dragging a slider never moves the list or the panel; values glide to their place
/// with the selection pill (one transition for every element that changes).
final class PaletteFontTunerView: NSView {
    private let strip = PaletteFontTargetStrip()
    private let sample = PaletteText.label(Typography.body, tone: nil)
    private let sampleBox = NSView()
    private let sizeRow = PaletteFontSliderRow(keys: ["⌘", "−", "="])
    private let lineHeightRow = PaletteFontSliderRow(keys: ["⌥", "⌘", "−", "="])
    private var tuner: PaletteFontTuner?
    private var appliedTarget: Int?
    var onSelectTarget: ((Int) -> Void)?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        sampleBox.wantsLayer = true
        sample.maximumNumberOfLines = 2
        sample.lineBreakMode = .byClipping
        sampleBox.addSubview(sample)
        [strip, sampleBox, sizeRow, lineHeightRow].forEach(addSubview)
        strip.onSelect = { [weak self] in self?.onSelectTarget?($0) }
        sizeRow.onChange = { [weak self] in self?.tuner?.setSize($0) }
        lineHeightRow.onChange = { [weak self] in self?.tuner?.setLineHeight($0) }
        setAccessibilityIdentifier("cmux.commandPalette.fontTuner")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: Geometry

    private static var controlRowHeight: CGFloat { PaletteLayout.actionsMenuRowHeight }
    private static var sampleHeight: CGFloat { PaletteLayout.rowHeight * 2 }
    private static var verticalPadding: CGFloat { Metrics.space3 }

    /// The dock's height under the list (`dock` and `inline`); the `side` column takes the list's
    /// height and ``sideWidth`` instead.
    static func height(for style: PaletteFontPickerStyle) -> CGFloat {
        switch style {
        case .dock: verticalPadding * 2 + controlRowHeight * 3 + sampleHeight + Metrics.space2 * 3
        case .inline: verticalPadding * 2 + controlRowHeight * 2 + Metrics.space2
        case .side: 0
        }
    }

    /// The `side` column's width: a little over a third of the palette.
    static var sideWidth: CGFloat { (PaletteLayout.width * 0.4).rounded() }

    // MARK: State

    func update(_ tuner: PaletteFontTuner) {
        let switched = self.tuner !== tuner || appliedTarget != tuner.targetIndex
        let animate = appliedTarget != nil && switched
        self.tuner = tuner
        appliedTarget = tuner.targetIndex
        strip.vertical = tuner.style == .side
        strip.update(titles: tuner.targets.map(\.title), selected: tuner.targetIndex, animated: animate)
        sizeRow.update(title: PaletteStrings.fontSize, row: tuner.target.size, value: tuner.size, animated: animate)
        lineHeightRow.update(title: PaletteStrings.fontLineHeight, row: tuner.target.lineHeight, value: tuner.lineHeight, animated: animate)
        sampleBox.isHidden = tuner.style == .inline
        applySample(tuner)
        needsLayout = true
    }

    /// The sample in the highlighted family at the chosen size (a size past what the box holds is
    /// clipped, as the surface would show it) and line height.
    private func applySample(_ tuner: PaletteFontTuner) {
        let size = CGFloat(tuner.size ?? Double(Typography.body.pointSize))
        let face = tuner.sampleFamily.flatMap { PaletteFontFaces.shared.font(family: $0, size: size) }
            ?? (tuner.target.sample == .code ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular) : NSFont.systemFont(ofSize: size))
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = CGFloat(tuner.lineHeight ?? 1)
        style.lineBreakMode = .byClipping
        performWithTheme {
            sample.attributedStringValue = NSAttributedString(string: PaletteFontSamples.block(tuner.target.sample), attributes: [
                .font: face, .foregroundColor: Palette.textPrimary, .paragraphStyle: style,
            ])
        }
        sample.setAccessibilityLabel(tuner.sampleTitle)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColors()
    }

    private func applyColors() {
        performWithTheme {
            sampleBox.layer?.backgroundColor = Palette.hoverFill.cgColor
            sampleBox.layer?.cornerRadius = PaletteLayout.rowCornerRadius
        }
        if let tuner { applySample(tuner) }
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        guard let tuner else { return }
        let padding = PaletteLayout.horizontalPadding
        let width = bounds.width - 2 * padding
        let row = Self.controlRowHeight
        var y = Self.verticalPadding
        switch tuner.style {
        case .dock:
            strip.frame = NSRect(x: padding, y: y, width: width, height: row)
            y += row + Metrics.space2
            sampleBox.frame = NSRect(x: padding, y: y, width: width, height: Self.sampleHeight)
            y += Self.sampleHeight + Metrics.space2
            sizeRow.frame = NSRect(x: padding, y: y, width: width, height: row)
            y += row + Metrics.space2
            lineHeightRow.frame = NSRect(x: padding, y: y, width: width, height: row)
        case .inline:
            strip.frame = NSRect(x: padding, y: y, width: width, height: row)
            y += row + Metrics.space2
            let half = (width - Metrics.space4) / 2
            sizeRow.frame = NSRect(x: padding, y: y, width: half, height: row)
            lineHeightRow.frame = NSRect(x: padding + half + Metrics.space4, y: y, width: half, height: row)
        case .side:
            // The column is as tall as the list, which can be short: the sliders stay pinned to
            // the bottom, the sample gives up height first, then the target rows tighten.
            let available = bounds.height - 2 * Self.verticalPadding
            let sliders = row * 2 + Metrics.space2
            let gaps = Metrics.space4 * 2
            let minSample = PaletteLayout.rowHeight
            let count = CGFloat(max(tuner.targets.count, 1))
            let stripRow = max(0, min(row, (available - sliders - gaps - minSample) / count))
            let stripHeight = stripRow * count
            strip.frame = NSRect(x: padding, y: y, width: width, height: stripHeight)
            y += stripHeight + Metrics.space4
            let sampleHeight = max(0, min(Self.sampleHeight * 1.5, available - stripHeight - gaps - sliders))
            sampleBox.frame = NSRect(x: padding, y: y, width: width, height: sampleHeight)
            let lineHeightY = bounds.height - Self.verticalPadding - row
            lineHeightRow.frame = NSRect(x: padding, y: lineHeightY, width: width, height: row)
            sizeRow.frame = NSRect(x: padding, y: lineHeightY - Metrics.space2 - row, width: width, height: row)
        }
        let inset = Metrics.space3
        sample.frame = sampleBox.bounds.insetBy(dx: inset, dy: inset / 2)
    }
}

// MARK: - Target strip

/// The targets as segments (a column in the `side` layout); the selected one sits on the selection
/// fill, which glides to a new selection. A click selects; Tab and Shift-Tab step (the palette's keys).
final class PaletteFontTargetStrip: NSView {
    var onSelect: ((Int) -> Void)?
    var vertical = false
    private let pill = NSView()
    private var labels: [PaletteLabel] = []
    private let tabCap = PaletteKeycapsView()
    private var selected = 0

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        pill.wantsLayer = true
        addSubview(pill)
        tabCap.keycaps = ["⇥"]
        addSubview(tabCap)
        setAccessibilityRole(.tabGroup)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(titles: [String], selected: Int, animated: Bool) {
        if labels.map(\.stringValue) != titles {
            labels.forEach { $0.removeFromSuperview() }
            labels = titles.map { title in
                let label = PaletteText.label(Typography.caption, tone: .secondary)
                label.stringValue = title
                label.alignment = .center
                label.setAccessibilityRole(.radioButton)
                addSubview(label)
                return label
            }
        }
        self.selected = selected
        for (index, label) in labels.enumerated() {
            label.tone = index == selected ? .primary : .secondary
            label.setAccessibilityValue(index == selected)
        }
        let target = pillFrame()
        if animated, pill.frame != .zero {
            Motion.overlays.animateTimed(.selection, in: self) { pill.animator().frame = target }
        } else {
            pill.frame = target
        }
        applyColors()
        needsLayout = true
    }

    private func slot(_ index: Int) -> NSRect {
        guard !labels.isEmpty else { return .zero }
        if vertical {
            let height = bounds.height / CGFloat(labels.count)
            return NSRect(x: 0, y: CGFloat(index) * height, width: bounds.width, height: height)
        }
        let capWidth = tabCap.intrinsicContentSize.width + Metrics.space2
        let width = (bounds.width - capWidth) / CGFloat(labels.count)
        return NSRect(x: CGFloat(index) * width, y: 0, width: width, height: bounds.height)
    }

    private func pillFrame() -> NSRect { slot(selected).insetBy(dx: Metrics.space1 / 2, dy: 0) }

    override func layout() {
        super.layout()
        for (index, label) in labels.enumerated() {
            let slot = slot(index)
            let height = PaletteText.height(label)
            if vertical { label.alignment = .left }
            let inset = vertical ? Metrics.space3 : Metrics.space1
            label.frame = pixelAligned(NSRect(x: slot.minX + inset, y: slot.midY - height / 2, width: slot.width - 2 * inset, height: height))
        }
        if pill.layer?.animationKeys()?.isEmpty ?? true { pill.frame = pillFrame() }
        let cap = tabCap.intrinsicContentSize
        tabCap.isHidden = vertical
        tabCap.frame = pixelAligned(NSRect(x: bounds.maxX - cap.width, y: (bounds.height - cap.height) / 2, width: cap.width, height: cap.height))
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let index = labels.indices.first(where: { slot($0).contains(point) }) { onSelect?(index) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        performWithTheme {
            pill.layer?.backgroundColor = Palette.selectionFill.cgColor
            pill.layer?.cornerRadius = PaletteLayout.rowCornerRadius
        }
    }
}
