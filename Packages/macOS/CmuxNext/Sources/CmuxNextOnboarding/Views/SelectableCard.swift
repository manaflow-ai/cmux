import AppKit
import CmuxNextDesign

/// A clickable card with a hover fill and a selection ring in the theme's
/// foreground (never the system accent).
class SelectableCard: ThemedView {
    /// ring: selection ring and fill (theme cards); fill: selection fill only
    /// (list rows); hover: hover fill only (check rows, whose mark shows state).
    enum Selection { case ring, fill, hover }

    var selection: Selection = .ring { didSet { refresh(animated: false) } }
    var onSelect: (() -> Void)?
    var isSelected = false { didSet { if oldValue != isSelected { refresh(animated: true) } } }
    private var hovering = false
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        cornerRadius = OnboardingMetrics.itemRadius + 2
        borderWidth = 1.5
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        refresh(animated: false)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; refresh(animated: true) }
    override func mouseExited(with event: NSEvent) { hovering = false; refresh(animated: true) }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onSelect?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onSelect?()
        return true
    }

    func refresh(animated: Bool) {
        let selected = isSelected && selection != .hover
        let hover = hovering
        let ring = selection == .ring
        fill = { selected ? Palette.selectionFill : (hover ? Palette.hoverFill : nil) }
        border = { ring ? (selected ? Palette.textPrimary.faded(0.85) : Palette.separator) : nil }
        setAccessibilityValue(selected)
        if animated, let layer {
            if let stroke = border()?.cgColor { Motion.set(layer, "borderColor", to: stroke, fade: .hover) }
            Motion.set(layer, "backgroundColor", to: fill()?.cgColor ?? NSColor.clear.cgColor, fade: .hover)
        }
    }
}

/// Theme card: swatch plus name.
final class ThemeCardView: SelectableCard {
    let swatch: ThemeSwatchView

    init(choice: ThemeChoice, title: String) {
        swatch = ThemeSwatchView(input: choice.input, showsChrome: false)
        super.init(frame: .zero)
        swatch.layer?.cornerRadius = OnboardingMetrics.itemRadius
        let label = OnboardingLabel.make(title, font: Typography.caption, color: Palette.textSecondary)
        label.alignment = .center
        addSubview(swatch)
        addSubview(label)
        let size = OnboardingMetrics.themeCardSize
        let pad = Metrics.space3
        NSLayoutConstraint.activate([
            swatch.topAnchor.constraint(equalTo: topAnchor, constant: pad),
            swatch.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            swatch.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            swatch.widthAnchor.constraint(equalToConstant: size.width),
            swatch.heightAnchor.constraint(equalToConstant: size.height * 0.62),
            label.topAnchor.constraint(equalTo: swatch.bottomAnchor, constant: Metrics.space3),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -pad),
        ])
        setAccessibilityLabel(title)
    }
}

/// Two or more options in one pill; the selected one gets the selection fill.
final class SegmentedPill: ThemedView {
    private var buttons: [OnboardingButton] = []
    var onSelect: ((Int) -> Void)?
    var selectedIndex = 0 { didSet { update() } }

    init(titles: [String]) {
        super.init(frame: .zero)
        fill = { Palette.hoverFill }
        let stack = NSStackView()
        stack.spacing = Metrics.space1
        stack.distribution = .fillEqually
        stack.setHuggingPriority(.required, for: .horizontal)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for (index, title) in titles.enumerated() {
            let button = OnboardingButton(title, style: .plain) { [weak self] in self?.onSelect?(index) }
            buttons.append(button)
            stack.addArrangedSubview(button)
        }
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.space1),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.space1),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.space1),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Metrics.space1),
        ])
        update()
    }

    override func layout() {
        super.layout()
        cornerRadius = bounds.height / 2
    }

    private func update() {
        for (index, button) in buttons.enumerated() {
            button.style = index == selectedIndex ? .secondary : .plain
        }
    }
}
