import AppKit

/// A discrete slider keeps its domain labels while changes use the popup's numeric wire value.
@MainActor
final class NativePopupSliderView: NSView {
    let slider = NativePopupDiscreteSlider()
    let currentLabel = ThemedLabel(labelWithString: "")
    private let heading: ThemedLabel
    private let minimumLabel: ThemedLabel
    private let maximumLabel: ThemedLabel
    private let recommendedLabel: ThemedLabel
    /// Its parts span the popup row's padded box (``PopupRowView/contentGuide``): the row layout
    /// of ``NativePopupContent``'s other rows owns the inset, so the slider moves with them.
    private let rowLayout = PopupRowView.Layout()
    private var descriptor: NativePopupSlider
    private var lastEmittedValue: String?
    var change: (String) -> Void = { _ in }
    var commit: () -> Void = {}
    var prepareCommit: (() -> (() -> Void)?)?
    var escape: () -> Void = {}
    var preferredHeight: CGFloat { descriptor.recommendedLabel == nil ? 84 : 104 }
    override var isFlipped: Bool { true }

    init(row: NativePopupRow, descriptor: NativePopupSlider) {
        self.descriptor = descriptor
        heading = ThemedLabel(labelWithString: row.label)
        minimumLabel = ThemedLabel(labelWithString: descriptor.minimumLabel ?? "")
        maximumLabel = ThemedLabel(labelWithString: descriptor.maximumLabel ?? "")
        recommendedLabel = ThemedLabel(labelWithString: descriptor.recommendedLabel ?? "")
        lastEmittedValue = descriptor.selectedValue
        super.init(frame: .zero)
        for label in [heading, currentLabel, minimumLabel, maximumLabel, recommendedLabel] {
            label.font = Typography.caption
            label.ink = row.disabled == true ? .tertiary : .secondary
            label.lineBreakMode = .byTruncatingTail
            addSubview(label)
        }
        heading.font = Typography.body
        currentLabel.alignment = .right
        maximumLabel.alignment = .right
        recommendedLabel.alignment = .center
        let cell = NativePopupDiscreteSliderCell()
        cell.minimal = descriptor.style == .minimal
        cell.stopCount = descriptor.stops.count
        cell.recommendedIndex = descriptor.stops.firstIndex { $0.value == descriptor.recommendedValue }
        slider.cell = cell
        slider.minValue = 0
        slider.maxValue = Double(max(1, descriptor.stops.count - 1))
        let selected = descriptor.stops.firstIndex { $0.value == descriptor.selectedValue }
        let fallback = descriptor.stops.firstIndex { $0.value == descriptor.defaultValue }
        let position = row.value.flatMap(Int.init).flatMap { descriptor.stops.indices.contains($0) ? $0 : nil }
        slider.doubleValue = Double(position ?? selected ?? fallback ?? 0)
        slider.isContinuous = true
        slider.isEnabled = row.disabled != true && !descriptor.stops.isEmpty
        slider.setAccessibilityLabel(descriptor.accessibilityLabel ?? row.label)
        slider.target = self
        slider.action = #selector(valueChanged(_:))
        slider.commitValue = { [weak self] close in
            guard let self, slider.isEnabled else { return }
            let finish: (() -> Void)?
            if !close { finish = nil }
            else if let prepareCommit { finish = prepareCommit() }
            else { finish = commit }
            publishValue()
            finish?()
        }
        slider.escape = { [weak self] in self?.escape() }
        addSubview(slider)
        setAccessibilityIdentifier(row.id)
        refreshValue()
    }

    required init?(coder: NSCoder) { nil }

    func update(row: NativePopupRow) {
        guard let descriptor = row.slider else { return }
        self.descriptor = descriptor
        if !slider.isInteracting {
            let selected = descriptor.stops.firstIndex { $0.value == descriptor.selectedValue }
            let fallback = descriptor.stops.firstIndex { $0.value == descriptor.defaultValue }
            slider.doubleValue = Double(row.value.flatMap(Int.init) ?? selected ?? fallback ?? 0)
            lastEmittedValue = descriptor.selectedValue
        }
        refreshValue()
    }

    override func layout() {
        super.layout()
        let start = rowLayout.leading
        let width = max(0, bounds.width - rowLayout.leading - rowLayout.trailing)
        heading.frame = NSRect(x: start, y: 5, width: width / 2, height: 20)
        currentLabel.frame = NSRect(x: start + width / 2, y: 5, width: width / 2, height: 20)
        slider.frame = NSRect(x: start, y: 29, width: width, height: 24)
        minimumLabel.frame = NSRect(x: start, y: 56, width: width / 2, height: 18)
        maximumLabel.frame = NSRect(x: start + width / 2, y: 56, width: width / 2, height: 18)
        recommendedLabel.frame = NSRect(x: start, y: 80, width: width, height: 18)
    }

    @objc private func valueChanged(_ sender: NSSlider) { publishValue() }

    private func refreshValue() {
        let index = min(max(0, Int(slider.doubleValue.rounded())), max(0, descriptor.stops.count - 1))
        slider.doubleValue = Double(index)
        guard descriptor.stops.indices.contains(index) else { return }
        let stop = descriptor.stops[index]
        currentLabel.stringValue = stop.label
        currentLabel.themedToolTip = stop.description
        slider.themedToolTip = stop.description
        slider.setAccessibilityValueDescription(stop.accessibilityLabel ?? stop.label)
    }

    private func publishValue() {
        refreshValue()
        let index = Int(slider.doubleValue)
        guard descriptor.stops.indices.contains(index) else { return }
        let value = descriptor.stops[index].value
        guard value != lastEmittedValue else { return }
        lastEmittedValue = value
        change(String(index))
    }
}

@MainActor
class NativePopupTrackingSlider: NSSlider {
    var isInteracting = false

    override func mouseDown(with event: NSEvent) {
        isInteracting = true
        defer { isInteracting = false }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        isInteracting = true
        defer { isInteracting = false }
        super.keyDown(with: event)
    }
}

@MainActor
final class NativePopupDiscreteSlider: NativePopupTrackingSlider {
    var commitValue: (Bool) -> Void = { _ in }
    var navigate: (UInt16) -> Bool = { _ in false }
    var escape: () -> Void = {}

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        super.mouseDown(with: event)
        commitValue(false)
    }

    override func keyDown(with event: NSEvent) {
        guard isEnabled else { return }
        isInteracting = true
        defer { isInteracting = false }
        if [125, 126].contains(event.keyCode), navigate(event.keyCode) { return }
        switch event.keyCode {
        case 36, 76: commitValue(true)
        case 53: escape()
        case 123, 125, 124, 126, 115, 119:
            if event.keyCode == 115 { doubleValue = minValue }
            else if event.keyCode == 119 { doubleValue = maxValue }
            else { doubleValue = min(maxValue, max(minValue, doubleValue + ([124, 126].contains(event.keyCode) ? 1 : -1))) }
            _ = sendAction(action, to: target)
        default: super.keyDown(with: event)
        }
    }
}

@MainActor
private final class NativePopupDiscreteSliderCell: NSSliderCell {
    var minimal = false
    var stopCount = 0
    var recommendedIndex: Int?

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        if let view = controlView { view.performWithTheme { drawTrack(rect) } }
        else { drawTrack(rect) }
    }

    private func drawTrack(_ rect: NSRect) {
        let track = NSRect(x: rect.minX, y: rect.midY - 1.5, width: rect.width, height: 3)
        Palette.textSecondary.withAlphaComponent(0.2).setFill()
        NSBezierPath(roundedRect: track, xRadius: 1.5, yRadius: 1.5).fill()
        let fraction = CGFloat((doubleValue - minValue) / max(1, maxValue - minValue))
        Palette.accentFill.withAlphaComponent(isEnabled ? (minimal ? 0.35 : 0.8) : 0.2).setFill()
        NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: track.width * fraction, height: track.height), xRadius: 1.5, yRadius: 1.5).fill()
        for index in 0..<stopCount {
            let x = track.minX + track.width * CGFloat(index) / CGFloat(max(1, stopCount - 1))
            Palette.textSecondary.setFill()
            NSBezierPath(ovalIn: NSRect(x: x - 1.5, y: track.midY - 1.5, width: 3, height: 3)).fill()
            if index == recommendedIndex {
                Palette.textSecondary.setStroke()
                NSBezierPath(ovalIn: NSRect(x: x - 3, y: track.midY - 3, width: 6, height: 6)).stroke()
            }
        }
    }

    override func drawKnob(_ knobRect: NSRect) {
        if let view = controlView { view.performWithTheme { drawThumb(knobRect) } }
        else { drawThumb(knobRect) }
    }

    private func drawThumb(_ knobRect: NSRect) {
        let diameter: CGFloat = minimal ? 8 : 12
        let knob = NSRect(x: knobRect.midX - diameter / 2, y: knobRect.midY - diameter / 2, width: diameter, height: diameter)
        (isEnabled ? Palette.textPrimary : Palette.textTertiary).setFill()
        NSBezierPath(ovalIn: knob).fill()
    }
}
