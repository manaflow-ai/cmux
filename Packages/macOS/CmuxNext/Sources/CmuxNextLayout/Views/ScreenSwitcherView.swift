import AppKit
import CmuxNextDesign

/// Glass capsule listing screens. Hidden unless `LayoutModel.showsScreenSwitcher`.
final class ScreenSwitcherView: NSView {
    /// Inset between the capsule edge and the pills.
    private static let inset: CGFloat = 3
    var onSelect: ((ScreenID) -> Void)?
    private let stack = NSStackView()
    private let glass: NSGlassEffectView
    private var items: [ScreenID: ScreenPillView] = [:]
    private var order: [ScreenID] = []

    override init(frame frameRect: NSRect) {
        let content = NSView()
        // Concentric capsule around the pills.
        glass = Glass.makePanel(content: content, cornerRadius: ScreenPillView.height / 2 + Self.inset)
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.spacing = Metrics.space1
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        addSubview(glass)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Self.inset),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Self.inset),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: Self.inset),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -Self.inset),
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
    static let height: CGFloat = 22
    private static let horizontalPadding: CGFloat = 10
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
        layer?.cornerRadius = Self.height / 2
        label.font = Typography.bodyEmphasized
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalPadding),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalPadding),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: Self.height),
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
        label.font = Typography.bodyEmphasized
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
