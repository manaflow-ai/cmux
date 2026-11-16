import AppKit
import CmuxNextDesign

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
