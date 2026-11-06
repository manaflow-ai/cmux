import AppKit
import CmuxNextDesign

/// A small gray label: the caption on a rounded hover-fill, 6 pt either side, 1 pt above and below.
final class AutomationChip: NSView {
    private let label = NSTextField(labelWithString: "")

    /// A chip showing `text` in `palette`.
    init(text: String, palette: AutomationsPalette) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Metrics.controlCornerRadius
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byClipping
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        show(text, palette: palette)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The chip's text.
    var text: String { label.stringValue }

    /// Shows `text` in `palette`.
    func show(_ text: String, palette: AutomationsPalette) {
        label.stringValue = text
        label.font = palette.caption
        label.textColor = palette.text
        layer?.backgroundColor = palette.hover.cgColor
    }
}
