public import AppKit
import CmuxNextDesign

/// The live hypothesis shown while terminal dictation is recording. It is
/// deliberately click-through so the terminal remains the input target.
public final class TerminalDictationPreview: NSView {
    private let label = ThemedLabel(labelWithString: "")
    private let glass = Glass.makeSurface(.toast, cornerRadius: 8, interactive: false)

    public init() {
        super.init(frame: .zero)
        glass.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: TypeScale.detail, weight: TypeScale.emphasis)
        label.ink = .secondary
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(label)
        addSubview(glass)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            label.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: glass.contentView.topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor, constant: -6),
            widthAnchor.constraint(lessThanOrEqualToConstant: 480),
        ])
        isHidden = true
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The terminal underneath remains clickable and focusable.
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public func show(volatileText: String) {
        let text = volatileText.isEmpty ? "Listening…" : "Listening… \(volatileText)"
        label.stringValue = text
        setAccessibilityLabel(text)
        isHidden = false
    }

    public func hide() {
        isHidden = true
        label.stringValue = ""
    }
}
