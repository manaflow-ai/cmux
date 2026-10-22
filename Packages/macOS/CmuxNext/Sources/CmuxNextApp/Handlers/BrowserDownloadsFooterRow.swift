import AppKit
import CmuxNextDesign

/// A Downloads popup footer command: an icon and a one-line title across the popup, with the hover
/// fill of the rows above. A button, so automation and VoiceOver press it.
final class BrowserDownloadsFooterRow: NSButton {
    private let symbol: String
    private let label: String
    private let run: @MainActor () -> Void
    private let hover = BrowserDownloadsHoverFill()

    init(symbol: String, title: String, identifier: String, run: @escaping @MainActor () -> Void) {
        self.symbol = symbol
        label = title
        self.run = run
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        bezelStyle = .regularSquare
        setAccessibilityLabel(title)
        setAccessibilityIdentifier(identifier)
        target = self
        action = #selector(clicked)
        hover.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hover, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            hover.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            hover.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            hover.topAnchor.constraint(equalTo: topAnchor),
            hover.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        apply(BrowserDownloadsPopupColors())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Draws in `colors` (the popup's theme scope).
    func apply(_ colors: BrowserDownloadsPopupColors) {
        hover.fill = colors.hover
        let text = NSMutableAttributedString()
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: TypeScale.body, weight: .regular).applying(.init(paletteColors: [colors.secondary]))) {
            let attachment = NSTextAttachment()
            attachment.image = image
            text.append(NSAttributedString(attachment: attachment))
        }
        text.append(NSAttributedString(string: "   " + label, attributes: [.font: Typography.body, .foregroundColor: colors.primary]))
        attributedTitle = text
        alignment = .left
    }

    override func drawFocusRingMask() {}

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 28) }

    /// The title starts after the row's 4 pt inset plus 8 pt padding, as the rows above.
    override func draw(_ dirtyRect: NSRect) {
        attributedTitle.draw(at: NSPoint(x: 12, y: (bounds.height - attributedTitle.size().height) / 2))
    }

    @objc private func clicked() { run() }
}
