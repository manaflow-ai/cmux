import AppKit
import CmuxNextCompat

/// The row a ``GlassMenuStepperItem`` draws in a ``GlassMenu``: its title on the menu's text column,
/// then, trailing, − · value · + and the reset arrow. The buttons run their items and leave the menu
/// open; the value and the buttons' enabled states are read again after each press and on
/// ``refresh()`` (the owner's state changed: a page's zoom settled).
@MainActor
final class GlassMenuStepperRowView: PopupRowView {
    let item: GlassMenuStepperItem
    let minus: GlassMenuStepperButton
    let plus: GlassMenuStepperButton
    let resetButton: GlassMenuStepperButton
    let valueLabel: ThemedLabel
    /// The value changed after the row first showed it (a press, a key, the page's zoom settling): the
    /// list announces it, so VoiceOver says the new zoom.
    var onNewValue: (String) -> Void = { _ in }

    init(_ item: GlassMenuStepperItem, leading: NSView?, layout: Layout) {
        self.item = item
        // Locals: no stored property is read before super.init.
        let minus = GlassMenuStepperButton(symbol: "minus", label: item.decrement.title, shortcut: GlassMenuRow.shortcut(item.decrement))
        let plus = GlassMenuStepperButton(symbol: "plus", label: item.increment.title, shortcut: GlassMenuRow.shortcut(item.increment))
        let reset = GlassMenuStepperButton(symbol: "arrow.counterclockwise", label: item.reset.title, shortcut: GlassMenuRow.shortcut(item.reset))
        self.minus = minus
        self.plus = plus
        resetButton = reset
        let digits = Typography.system(.monospacedDigit, size: Typography.body.pointSize)
        let value = ThemedLabel(labelWithString: "")
        value.font = digits
        value.alignment = .center
        value.ink = .primary
        value.setAccessibilityElement(false)
        value.translatesAutoresizingMaskIntoConstraints = false
        // "500%" fits, so the buttons stay put while the value changes.
        value.widthAnchor.constraint(equalToConstant: Self.valueWidth(digits)).isActive = true
        valueLabel = value
        let controls = NSStackView(views: [minus, value, plus, reset])
        controls.orientation = .horizontal
        controls.spacing = 2
        controls.setCustomSpacing(8, after: plus)
        super.init(leading: leading, title: item.title, trailing: controls, layout: layout)
        // One of the menu's items for VoiceOver ("Zoom, 100%"): the buttons are its children, the
        // value its value.
        setAccessibilityRole(.menuItem)
        minus.onPress = { [weak self] in self?.run(item.decrement) }
        plus.onPress = { [weak self] in self?.run(item.increment) }
        reset.onPress = { [weak self] in self?.run(item.reset) }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The value's column (points): wide enough for "500%" in `font`.
    static func valueWidth(_ font: NSFont) -> CGFloat {
        (("500%" as NSString).size(withAttributes: [.font: font]).width + 6).rounded(.up)
    }

    /// Reads the value and which buttons can run.
    func refresh() {
        item.validate()
        let value = item.value()
        let shown = valueLabel.stringValue
        valueLabel.stringValue = value
        setAccessibilityValue(value)
        minus.isEnabled = item.isEnabled(item.decrement)
        plus.isEnabled = item.isEnabled(item.increment)
        resetButton.isEnabled = item.isEnabled(item.reset)
        if !shown.isEmpty, shown != value { onNewValue(value) }
    }

    /// Runs `part` with the menu open, then shows its result.
    @discardableResult
    func run(_ part: NSMenuItem) -> Bool {
        let ran = item.run(part)
        refresh()
        return ran
    }

    /// The keys on the highlighted row: Left −, Right +, Return or Enter reset. False for any other key.
    ///
    /// The press runs on the next pass of the run loop, after the key, as every row of a
    /// ``GlassMenu`` runs: a key in an open menu is a pick, like a click. Run inside the key, the
    /// App's action rows validate as disabled (its key router already handled that key, so a row's
    /// own shortcut may not fire for it): the zoom did not change and its buttons read dimmed.
    func handleKey(_ event: NSEvent) -> Bool {
        let part: NSMenuItem
        switch event.keyCode {
        case 123: part = item.decrement
        case 124: part = item.increment
        case 36, 76: part = item.reset
        default: return false
        }
        MainRunLoopBlock.perform { [weak self] in self?.run(part) }
        return true
    }

    /// A row-wide click (not on a button) runs nothing: the menu stays open.
    override func activate() {}

}
