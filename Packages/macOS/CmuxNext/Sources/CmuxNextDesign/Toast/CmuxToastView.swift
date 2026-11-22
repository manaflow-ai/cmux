public import AppKit

/// A toast: the message, the action button and a close button on an
/// overlay surface. VoiceOver reads the message; the buttons are reachable
/// with VoiceOver and by click. The pointer on it holds it (`onHover`).
@MainActor
public final class CmuxToastView: NSView {
    public let toast: CmuxToast
    public private(set) var actionButton: CmuxToastButton?
    public let closeButton = CmuxToastButton(style: .close, title: CmuxToastStrings.dismiss, target: nil, action: nil)
    var onAction: (() -> Void)?
    var onClose: (() -> Void)?
    /// The pointer came onto or left the toast, or the toast moved or went
    /// under a still pointer (`PointerHover`, cx-3wu5).
    var onHover: ((Bool) -> Void)?
    private var pointerHover: PointerHover?
    /// Whether the pointer is on the toast now (as of the last refresh).
    public var isHovered: Bool { pointerHover?.isHovering ?? false }

    public init(toast: CmuxToast) {
        self.toast = toast
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build()
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(toast.message)
        setAccessibilityIdentifier("cmux.toast.\(toast.id)")
        pointerHover = PointerHover(self) { [weak self] hovering in self?.onHover?(hovering) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func build() {
        let label = NSTextField(wrappingLabelWithString: toast.message)
        label.font = Typography.body
        label.maximumNumberOfLines = 3
        label.preferredMaxLayoutWidth = 360
        // A wrapping label resists compression at only `.defaultLow`, the same as the stack's
        // hugging, so the toast's fitting size squeezed the message to 4 pt and drew only the
        // buttons. The message keeps its width (up to 360 pt, then it wraps).
        label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        performWithTheme { label.textColor = Palette.textPrimary }
        let row = NSStackView(views: [label])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Metrics.space2
        // The message sits at the pane text inset; the buttons' hover fills stop one small step
        // short of the edge, so the toast reads as one material with text in it.
        row.edgeInsets = NSEdgeInsets(top: Metrics.space2, left: Metrics.space4,
                                      bottom: Metrics.space2, right: Metrics.space2)
        row.translatesAutoresizingMaskIntoConstraints = false
        if let action = toast.action {
            let button = CmuxToastButton(style: .action, title: action.title, target: self, action: #selector(runAction))
            actionButton = button
            row.addArrangedSubview(button)
            row.setCustomSpacing(Metrics.space3, after: label)
        }
        closeButton.target = self
        closeButton.action = #selector(close)
        row.addArrangedSubview(closeButton)

        let content = NSView()
        content.addSubview(row)
        let surface = Glass.makeOverlayPanel(content: content)
        addSubview(surface)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            row.topAnchor.constraint(equalTo: content.topAnchor),
            row.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalTo: row.widthAnchor),
            heightAnchor.constraint(equalTo: row.heightAnchor),
        ])
    }

    @objc private func runAction() { onAction?() }
    @objc private func close() { onClose?() }
}
