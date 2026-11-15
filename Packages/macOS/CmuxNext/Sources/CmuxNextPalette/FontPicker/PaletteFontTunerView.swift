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
            let stripHeight = row * CGFloat(tuner.targets.count)
            strip.frame = NSRect(x: padding, y: y, width: width, height: stripHeight)
            y += stripHeight + Metrics.space4
            sampleBox.frame = NSRect(x: padding, y: y, width: width, height: Self.sampleHeight * 1.5)
            y += Self.sampleHeight * 1.5 + Metrics.space4
            sizeRow.frame = NSRect(x: padding, y: y, width: width, height: row)
            y += row + Metrics.space2
            lineHeightRow.frame = NSRect(x: padding, y: y, width: width, height: row)
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

// MARK: - Slider row

/// One slider row: its name, the slider, the value ("13 pt", "160%") and its keys. A target without
/// the setting shows the row dimmed with an en dash, so the dock keeps its shape.
final class PaletteFontSliderRow: NSView {
    var onChange: ((Double) -> Void)?
    private let title = PaletteText.label(Typography.caption, tone: .secondary)
    private let value = PaletteText.label(Typography.caption, tone: .primary)
    private let keys = PaletteKeycapsView()
    let slider = PaletteFontSlider()

    override var isFlipped: Bool { true }

    init(keys caps: [String]) {
        super.init(frame: .zero)
        keys.keycaps = caps
        value.alignment = .right
        [title, slider, value, keys].forEach(addSubview)
        slider.onChange = { [weak self] in self?.onChange?($0) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(title text: String, row: PaletteSettingRow?, value current: Double?, animated: Bool) {
        title.stringValue = text
        guard let number = row?.number, let current else {
            slider.isEnabled = false
            value.stringValue = "–"
            alphaValue = 0.45
            return
        }
        alphaValue = 1
        slider.isEnabled = true
        slider.set(range: number.range, value: current, animated: animated)
        value.stringValue = number.format(current)
        slider.setAccessibilityLabel(text)
        slider.setAccessibilityValue(number.format(current))
    }

    override func layout() {
        super.layout()
        let titleWidth = max(PaletteText.fittingWidth(title), bounds.width * 0.22)
        let valueWidth = bounds.width * 0.14
        let cap = keys.intrinsicContentSize
        let midY = bounds.midY
        title.frame = pixelAligned(NSRect(x: 0, y: midY - PaletteText.height(title) / 2, width: titleWidth, height: PaletteText.height(title)))
        keys.frame = pixelAligned(NSRect(x: bounds.maxX - cap.width, y: midY - cap.height / 2, width: cap.width, height: cap.height))
        let valueX = keys.frame.minX - Metrics.space3 - valueWidth
        value.frame = pixelAligned(NSRect(x: valueX, y: midY - PaletteText.height(value) / 2, width: valueWidth, height: PaletteText.height(value)))
        let sliderX = title.frame.maxX + Metrics.space3
        slider.frame = NSRect(x: sliderX, y: 0, width: max(0, valueX - Metrics.space3 - sliderX), height: bounds.height)
    }
}

/// A slider drawn with the palette's tokens: a thin track in the separator ink, the part up to the
/// value in the secondary ink and a round knob in the primary ink. Drag or click to set; the value
/// snaps on the setting's step through ``PaletteFontTuner``.
final class PaletteFontSlider: NSView {
    var onChange: ((Double) -> Void)?
    var isEnabled = true
    private let track = NSView()
    private let fill = NSView()
    private let knob = NSView()
    private var range: ClosedRange<Double> = 0...1
    private var value: Double = 0

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        [track, fill, knob].forEach {
            $0.wantsLayer = true
            addSubview($0)
        }
        setAccessibilityRole(.slider)
        setAccessibilityElement(true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var knobSize: CGFloat { Metrics.space4 + Metrics.space1 }
    private var trackHeight: CGFloat { Metrics.space1 }

    func set(range: ClosedRange<Double>, value: Double, animated: Bool) {
        self.range = range
        self.value = value
        let frames = partFrames()
        if animated, knob.frame != .zero {
            Motion.overlays.animateTimed(.move, in: self) {
                fill.animator().frame = frames.fill
                knob.animator().frame = frames.knob
            }
        } else {
            fill.frame = frames.fill
            knob.frame = frames.knob
        }
    }

    private func fraction() -> CGFloat {
        let span = range.upperBound - range.lowerBound
        return span > 0 ? CGFloat((value - range.lowerBound) / span) : 0
    }

    private func partFrames() -> (track: NSRect, fill: NSRect, knob: NSRect) {
        let usable = max(0, bounds.width - knobSize)
        let midY = bounds.midY
        let track = NSRect(x: knobSize / 2, y: midY - trackHeight / 2, width: usable, height: trackHeight)
        let x = knobSize / 2 + usable * fraction()
        let fill = NSRect(x: track.minX, y: track.minY, width: x - track.minX, height: trackHeight)
        let knob = NSRect(x: x - knobSize / 2, y: midY - knobSize / 2, width: knobSize, height: knobSize)
        return (track, fill, knob)
    }

    override func layout() {
        super.layout()
        let frames = partFrames()
        track.frame = frames.track
        if fill.layer?.animationKeys()?.isEmpty ?? true { fill.frame = frames.fill }
        if knob.layer?.animationKeys()?.isEmpty ?? true { knob.frame = frames.knob }
        applyColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        performWithTheme {
            track.layer?.backgroundColor = Palette.separator.cgColor
            fill.layer?.backgroundColor = Palette.textSecondary.cgColor
            knob.layer?.backgroundColor = Palette.textPrimary.cgColor
        }
        track.layer?.cornerRadius = trackHeight / 2
        fill.layer?.cornerRadius = trackHeight / 2
        knob.layer?.cornerRadius = knobSize / 2
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        report(event)
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            report(next)
            if next.type == .leftMouseUp { break }
        }
    }

    private func report(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let usable = max(1, bounds.width - knobSize)
        let fraction = min(1, max(0, (point.x - knobSize / 2) / usable))
        onChange?(range.lowerBound + Double(fraction) * (range.upperBound - range.lowerBound))
    }
}
