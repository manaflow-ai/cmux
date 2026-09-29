import AppKit
import CmuxNextDesign

/// Glass capsule listing screens. Hidden unless `LayoutModel.showsScreenSwitcher`.
final class ScreenSwitcherView: NSView {
    var onSelect: ((ScreenID) -> Void)?
    private let stack = NSStackView()
    private let glass: NSGlassEffectView
    private var items: [ScreenID: ScreenPillView] = [:]
    private var order: [ScreenID] = []

    override init(frame frameRect: NSRect) {
        let content = NSView()
        glass = Glass.makePanel(content: content, cornerRadius: 14)
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        addSubview(glass)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 3),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -3),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 3),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -3),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel(LayoutStrings.screenSwitcherAccessibility)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func update(screens: [LayoutScreen], active: ScreenID?) {
        let ids = screens.map(\.id)
        if ids != order {
            for view in stack.arrangedSubviews { view.removeFromSuperview() }
            var next: [ScreenID: ScreenPillView] = [:]
            for screen in screens {
                let pill = items[screen.id] ?? ScreenPillView(id: screen.id)
                pill.onClick = { [weak self] id in self?.onSelect?(id) }
                next[screen.id] = pill
                stack.addArrangedSubview(pill)
            }
            items = next
            order = ids
        }
        for (index, screen) in screens.enumerated() {
            let title = screen.name.isEmpty ? LayoutStrings.screenFallbackName(index + 1) : screen.name
            items[screen.id]?.update(title: title, selected: screen.id == active)
        }
    }
}

private final class ScreenPillView: NSView {
    let id: ScreenID
    var onClick: ((ScreenID) -> Void)?
    private let label = NSTextField(labelWithString: "")
    private var selected = false
    private var hovered = false
    private var trackingArea: NSTrackingArea?

    init(id: ScreenID) {
        self.id = id
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 11
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 22),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func update(title: String, selected: Bool) {
        label.stringValue = title
        self.selected = selected
        setAccessibilityLabel(title)
        setAccessibilityValue(selected)
        applyColors()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; applyColors() }
    override func mouseExited(with event: NSEvent) { hovered = false; applyColors() }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?(id) }
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?(id)
        return true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        label.textColor = selected ? Palette.textPrimary : Palette.textSecondary
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let fill: NSColor = selected ? Palette.selectionFill : (hovered ? Palette.hoverFill : .clear)
            layer?.backgroundColor = fill.cgColor
        }
    }
}
