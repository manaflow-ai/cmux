import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// One value: a dot when it differs from the base, its label (help on hover, with the base's value), a slider, the
/// exact number and a reset. The view keeps one per entry and calls ``update()`` after every change of the model.
final class DensityPlaygroundRow: NSView, NSTextFieldDelegate {
    typealias Size = DensityPlaygroundView.Size

    let entry: DensityTokenCatalog.Entry
    private let model: DensityPlaygroundModel
    private let dot = NSView()
    private let label = NSTextField(labelWithString: "")
    let slider = NSSlider()
    let field = ThemedTextField()
    private lazy var fieldBox = ThemedFieldBox(field: field, height: DensityPlaygroundButton.height)
    private let unit = NSTextField(labelWithString: "")
    private lazy var reset = DensityPlaygroundButton(image: NSImage.icon(.actionUndo, size: 12), label: SettingsWindowStrings.reset,
                                                     target: self, action: #selector(resetValue))
    private var shownChanged: Bool?

    init(model: DensityPlaygroundModel, entry: DensityTokenCatalog.Entry) {
        self.model = model
        self.entry = entry
        super.init(frame: .zero)
        build()
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Whether the exact field has the keyboard (its text is the user's until the edit ends).
    var isEditing: Bool { field.currentEditor() != nil }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(entry.label)
        setAccessibilityIdentifier("cmux.densityPlayground.row.\(entry.key)")

        dot.wantsLayer = true
        dot.layer?.cornerRadius = Size.dot / 2
        dot.setAccessibilityElement(false)

        label.stringValue = entry.label
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.setContentHuggingPriority(.init(1), for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        slider.minValue = entry.range.lowerBound
        slider.maxValue = entry.range.upperBound
        slider.isContinuous = true
        slider.controlSize = .small
        slider.target = self
        slider.action = #selector(slid)
        slider.setAccessibilityLabel(entry.label)

        field.alignment = .right
        field.font = Size.digits
        field.delegate = self
        field.setAccessibilityLabel(entry.label)

        unit.stringValue = entry.unit == .factor ? "×" : "pt"
        unit.font = Size.caption

        let stack = NSStackView(views: [dot, label, slider, fieldBox, unit, reset])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Size.gap
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Size.rowHeight),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Size.pad),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Size.pad),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: Size.dot),
            dot.heightAnchor.constraint(equalToConstant: Size.dot),
            slider.widthAnchor.constraint(equalToConstant: Size.slider),
            fieldBox.widthAnchor.constraint(equalToConstant: Size.field),
            unit.widthAnchor.constraint(equalToConstant: 14),
        ])
    }

    /// Reads the model: the value (the field only while it is not being edited), whether it differs from the base, the
    /// help and the theme's colors.
    func update() {
        let tokens = SettingsTheme.shared.tokens
        let changed = model.isChanged(entry)
        let value = model.value(entry) ?? entry.range.lowerBound
        let clamped = min(max(value, entry.range.lowerBound), entry.range.upperBound)
        if slider.doubleValue != clamped { slider.doubleValue = clamped }
        if !isEditing {
            let text = DensityPlaygroundModel.format(value)
            if field.stringValue != text { field.stringValue = text }
        }
        if shownChanged != changed {
            shownChanged = changed
            label.font = changed ? Size.labelChanged : Size.label
            dot.alphaValue = changed ? 1 : 0
            reset.alphaValue = changed ? 1 : 0
            reset.isEnabled = changed
        }
        label.themedToolTip = help
        label.textColor = tokens.textPrimary.nsColor
        unit.textColor = tokens.textTertiary.nsColor
        dot.layer?.backgroundColor = tokens.focusRing.cgColor
        slider.trackFillColor = tokens.focusRing.nsColor
        reset.applyStyle()
    }

    private var help: String {
        guard let base = model.baseValue(entry) else { return entry.help }
        return "\(entry.help) \(model.name(model.base)): \(DensityPlaygroundModel.format(base))."
    }

    @objc private func slid() {
        model.set(entry, to: slider.doubleValue)
        update()
    }

    @objc private func resetValue() {
        model.reset(entry)
        update()
    }

    /// Return, Tab or a click elsewhere ends the edit: the typed number is set.
    func controlTextDidEndEditing(_ notification: Notification) {
        commit()
    }

    private func commit() {
        let typed = field.stringValue.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        guard let number = Double(typed) else {
            field.stringValue = DensityPlaygroundModel.format(model.value(entry) ?? entry.range.lowerBound)
            return
        }
        // Leaving a field as shown writes nothing (it shows a rounded value).
        if let current = model.value(entry), typed == DensityPlaygroundModel.format(current) || abs(current - number) < 0.0001 { return }
        model.set(entry, to: number)
        field.stringValue = DensityPlaygroundModel.format(model.value(entry) ?? number)
        update()
    }
}
