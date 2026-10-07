public import AppKit

/// A toast: the message, the action button and a close button on an
/// overlay surface. VoiceOver reads the message; the buttons are reachable
/// with VoiceOver and by click. The pointer on it holds it (`onHover`).
@MainActor
public final class CmuxToastView: NSView {
    public let toast: CmuxToast
    public private(set) var actionButton: CmuxDialogButtonView?
    public let closeButton = NSButton()
    var onAction: (() -> Void)?
    var onClose: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    private var tracking: NSTrackingArea?

    public init(toast: CmuxToast) {
        self.toast = toast
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build()
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(toast.message)
        setAccessibilityIdentifier("cmux.toast.\(toast.id)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func build() {
        let label = NSTextField(wrappingLabelWithString: toast.message)
        label.font = Typography.body
        label.maximumNumberOfLines = 3
        label.preferredMaxLayoutWidth = 360
        performWithTheme { label.textColor = Palette.textPrimary }
        let row = NSStackView(views: [label])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Metrics.space3
        let padding = Metrics.space4
        row.edgeInsets = NSEdgeInsets(top: Metrics.space2, left: padding, bottom: Metrics.space2, right: Metrics.space2)
        row.translatesAutoresizingMaskIntoConstraints = false
        if let action = toast.action {
            let button = CmuxDialogButtonView(CmuxDialogButton(id: "action", title: action.title, role: .default),
                                              target: self, action: #selector(runAction))
            actionButton = button
            row.addArrangedSubview(button)
        }
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: CmuxToastStrings.dismiss)
        closeButton.isBordered = false
        closeButton.target = self
        closeButton.action = #selector(close)
        closeButton.setAccessibilityLabel(CmuxToastStrings.dismiss)
        performWithTheme { closeButton.contentTintColor = Palette.textSecondary }
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

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    public override func mouseEntered(with event: NSEvent) { onHover?(true) }
    public override func mouseExited(with event: NSEvent) { onHover?(false) }
}
