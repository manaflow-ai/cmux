public import AppKit
import CmuxNextDesign

/// The live hypothesis shown while terminal dictation is recording. It is
/// deliberately click-through so the terminal remains the input target.
public final class TerminalDictationPreview: NSView {
    private let label = ThemedLabel(labelWithString: "")

    public init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = Metrics.lineWidth(1)
        label.font = .systemFont(ofSize: TypeScale.detail, weight: TypeScale.emphasis)
        label.ink = .secondary
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            widthAnchor.constraint(lessThanOrEqualToConstant: 480),
        ])
        isHidden = true
        setAccessibilityRole(.staticText)
        applyThemeColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyThemeColors()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyThemeColors()
    }

    private func applyThemeColors() {
        performWithTheme {
            layer?.backgroundColor = Palette.elevatedBackground.cgColor
            layer?.borderColor = Palette.separator.cgColor
        }
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
