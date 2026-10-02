import AppKit
import CmuxNextDesign

/// One role in the grid: a radio button in a fixed-size cell whose fill
/// steps from clear to hover to pressed to selected (theme tokens, Motion's
/// hover fade). A click anywhere in the cell picks the role; the cell never
/// changes size, so hovering moves nothing.
final class RoleCell: ThemedView {
    let radio: NSButton
    private var hovered = false
    private var pressed = false
    private var tracking: NSTrackingArea?

    init(title: String, target: AnyObject?, action: Selector) {
        radio = OnboardingControl.radio(title, target: target, action: action)
        super.init(frame: .zero)
        cornerRadius = 8
        fill = { [weak self] in self?.currentFill }
        addSubview(radio)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            radio.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            radio.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            radio.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var isOn: Bool { radio.state == .on }

    func setOn(_ on: Bool) {
        guard isOn != on else { return }
        radio.state = on ? .on : .off
        refresh()
    }

    private var currentFill: NSColor {
        if pressed { return Palette.pressedFill }
        if isOn { return Palette.selectionFill }
        return hovered ? Palette.hoverFill : .clear
    }

    /// Fades to the fill for the current state.
    private func refresh() {
        guard let layer else { return }
        Motion.set(layer, "backgroundColor", to: currentFill.cgColor, fade: .hover)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        refresh()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        pressed = false
        refresh()
    }

    override func mouseDown(with event: NSEvent) {
        pressed = true
        refresh()
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        refresh()
        if inside, !isOn { radio.performClick(nil) }
    }
}
