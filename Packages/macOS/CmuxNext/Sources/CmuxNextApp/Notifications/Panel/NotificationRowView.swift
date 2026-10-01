import AppKit
import CmuxNextDesign

/// One notification in the panel: unread dot, title and time, the source
/// workspace, the body (two lines), and a dismiss button. A click opens it;
/// a right click shows the row's actions.
final class NotificationRowView: NSView {
    struct Callbacks {
        var open: () -> Void
        var dismiss: () -> Void
        var menu: () -> NSMenu
    }

    let row: NotificationsPanelRow
    private let callbacks: Callbacks
    private let dot = NSView()
    var isSelected = false { didSet { needsDisplay = true } }

    private static let timeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    init(row: NotificationsPanelRow, now: Date, callbacks: Callbacks) {
        self.row = row
        self.callbacks = callbacks
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Metrics.space2
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false
        build(now: now)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel([row.title, row.workspaceTitle, row.body].compactMap { $0 }.joined(separator: ", "))
        setAccessibilityIdentifier("cmux.notifications.row")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = isSelected ? resolvedCGColor(Palette.selectionFill) : nil
        dot.layer?.backgroundColor = resolvedCGColor(Palette.attention)
    }

    private func resolvedCGColor(_ color: NSColor) -> CGColor {
        var result = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { result = color.cgColor }
        return result
    }

    private func build(now: Date) {
        dot.wantsLayer = true
        dot.layer?.cornerRadius = Metrics.space2 / 2
        dot.isHidden = !row.unread
        dot.translatesAutoresizingMaskIntoConstraints = false

        let title = Self.label(row.subtitle.map { "\(row.title) · \($0)" } ?? row.title,
                               font: row.unread ? Typography.bodyEmphasized : Typography.body, color: Palette.textPrimary)
        let time = Self.label(Self.timeFormatter.localizedString(for: row.createdAt, relativeTo: now),
                              font: Typography.caption, color: Palette.textTertiary)
        time.setContentCompressionResistancePriority(.required, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [title, time])
        header.spacing = Metrics.space2
        header.alignment = .firstBaseline

        var lines: [NSView] = [header]
        if let workspace = row.workspaceTitle {
            lines.append(Self.label(workspace, font: Typography.caption, color: Palette.textTertiary))
        }
        if !row.body.isEmpty {
            let body = Self.label(row.body, font: Typography.caption, color: Palette.textSecondary)
            body.maximumNumberOfLines = 2
            // The list width less the dot, the close button and the gaps.
            body.preferredMaxLayoutWidth = NotificationsPanelView.listWidth - 4 * Metrics.space2 - Metrics.space2 - Metrics.space6
            body.lineBreakMode = .byTruncatingTail
            body.cell?.wraps = true
            lines.append(body)
        }
        let text = NSStackView(views: lines)
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = Metrics.space1 / 2
        for line in lines { line.widthAnchor.constraint(lessThanOrEqualTo: text.widthAnchor).isActive = true }
        header.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true

        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: NotificationsPanelStrings.dismiss) ?? NSImage(),
                             target: self, action: #selector(dismissPressed))
        close.isBordered = false
        close.contentTintColor = Palette.textTertiary
        close.toolTip = NotificationsPanelStrings.dismiss
        close.setAccessibilityIdentifier("cmux.notifications.dismiss")
        close.translatesAutoresizingMaskIntoConstraints = false

        text.translatesAutoresizingMaskIntoConstraints = false
        for view in [dot, text, close] { addSubview(view) }
        let inset = Metrics.space2
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: Metrics.space2),
            dot.heightAnchor.constraint(equalTo: dot.widthAnchor),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            dot.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            text.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: inset),
            text.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
            close.leadingAnchor.constraint(equalTo: text.trailingAnchor, constant: inset),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            close.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: Metrics.space6),
        ])
    }

    static func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        return label
    }

    @objc private func dismissPressed() { callbacks.dismiss() }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { callbacks.open() }
    }

    override func menu(for event: NSEvent) -> NSMenu? { callbacks.menu() }

    override func accessibilityPerformPress() -> Bool {
        callbacks.open()
        return true
    }
}
