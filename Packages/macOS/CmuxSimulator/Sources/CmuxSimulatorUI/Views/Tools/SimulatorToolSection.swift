import AppKit

@MainActor
protocol SimulatorToolsSection: AnyObject {
    func update()
}

@MainActor
class SimulatorToolSection: NSBox {
    let contentStack = NSStackView()

    init(_ title: LocalizedStringResource) {
        super.init(frame: .zero)
        boxType = .primary
        titlePosition = .atTop
        titleFont = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        self.title = String(localized: title)
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 8
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func add(_ view: NSView) {
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        contentStack.addArrangedSubview(view)
        view.widthAnchor.constraint(lessThanOrEqualTo: contentStack.widthAnchor).isActive = true
    }
}

@MainActor
func simulatorRow(_ views: [NSView], spacing: CGFloat = 6) -> NSStackView {
    let row = NSStackView(views: views)
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = spacing
    return row
}

@MainActor
func simulatorLabel(
    _ text: String,
    font: NSFont = .systemFont(ofSize: NSFont.smallSystemFontSize),
    color: NSColor = .labelColor
) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: text)
    label.font = font
    label.textColor = color
    label.maximumNumberOfLines = 0
    return label
}

@MainActor
func simulatorValueRow(_ title: LocalizedStringResource, value: String) -> NSStackView {
    let titleLabel = simulatorLabel(String(localized: title), color: .secondaryLabelColor)
    let valueLabel = simulatorLabel(value)
    valueLabel.lineBreakMode = .byTruncatingMiddle
    valueLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    return simulatorRow([titleLabel, spacer, valueLabel])
}

@MainActor
final class SimulatorClosurePopUpButton: NSPopUpButton {
    var handler: ((Int) -> Void)?

    override init(frame buttonFrame: NSRect, pullsDown flag: Bool) {
        super.init(frame: buttonFrame, pullsDown: flag)
        target = self
        action = #selector(invoke)
        controlSize = .small
    }

    convenience init() {
        self.init(frame: .zero, pullsDown: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func invoke() {
        handler?(indexOfSelectedItem)
    }
}

@MainActor
final class SimulatorClosureSwitch: NSStackView {
    private let toggle = NSSwitch()
    var handler: ((Bool) -> Void)?

    var state: NSControl.StateValue {
        get { toggle.state }
        set { toggle.state = newValue }
    }

    var isEnabled: Bool {
        get { toggle.isEnabled }
        set {
            toggle.isEnabled = newValue
            arrangedSubviews.compactMap { $0 as? NSTextField }.forEach {
                $0.textColor = newValue ? .labelColor : .disabledControlTextColor
            }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        orientation = .horizontal
        alignment = .centerY
        spacing = 6
        toggle.target = self
        toggle.action = #selector(invoke)
        toggle.controlSize = .small
        addArrangedSubview(toggle)
    }

    convenience init(title: String, handler: ((Bool) -> Void)? = nil) {
        self.init(frame: .zero)
        addArrangedSubview(simulatorLabel(title))
        self.handler = handler
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func invoke() {
        handler?(toggle.state == .on)
    }
}

@MainActor
final class SimulatorClosureTextField: NSTextField, NSTextFieldDelegate {
    var onChange: ((String) -> Void)?
    var onSubmit: ((String) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        delegate = self
        controlSize = .small
    }

    convenience init(value: String = "", placeholder: String? = nil) {
        self.init(frame: .zero)
        stringValue = value
        placeholderString = placeholder
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func controlTextDidChange(_ notification: Notification) {
        onChange?(stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
        onSubmit?(stringValue)
        return true
    }
}

@MainActor
final class SimulatorClosureTextView: NSScrollView, NSTextViewDelegate {
    let textView = NSTextView()
    var onChange: ((String) -> Void)?

    var string: String {
        get { textView.string }
        set {
            guard textView.string != newValue else { return }
            textView.string = newValue
        }
    }

    init(value: String = "", minimumHeight: CGFloat = 64) {
        super.init(frame: .zero)
        hasVerticalScroller = true
        borderType = .bezelBorder
        drawsBackground = true
        textView.string = value
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        textView.delegate = self
        documentView = textView
        heightAnchor.constraint(greaterThanOrEqualToConstant: minimumHeight).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func textDidChange(_ notification: Notification) {
        onChange?(textView.string)
    }
}
