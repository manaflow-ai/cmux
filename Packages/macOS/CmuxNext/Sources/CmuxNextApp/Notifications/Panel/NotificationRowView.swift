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
    private var close: NSButton?
    /// Each label and the color it draws in, applied in the view's theme scope.
    private var tinted: [(NSTextField, Tone)] = []
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

    /// The text colors the panel uses.
    enum Tone {
        case primary, secondary, tertiary

        /// theme-scoped: read inside `performWithTheme`.
        var color: NSColor {
            switch self {
            case .primary: Palette.textPrimary
            case .secondary: Palette.textSecondary
            case .tertiary: Palette.textTertiary
            }
        }
    }

    override func updateLayer() {
        performWithTheme {
            layer?.backgroundColor = isSelected ? Palette.selectionFill.cgColor : nil
            dot.layer?.backgroundColor = Palette.attention.cgColor
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        performWithTheme {
            for (label, tone) in tinted { label.textColor = tone.color }
            close?.contentTintColor = Palette.textTertiary
        }
        needsDisplay = true
    }

    private func build(now: Date) {
        dot.wantsLayer = true
        dot.layer?.cornerRadius = Metrics.space2 / 2
        dot.isHidden = !row.unread
        dot.translatesAutoresizingMaskIntoConstraints = false

        let title = Self.label(row.subtitle.map { "\(row.title) · \($0)" } ?? row.title,
                               font: row.unread ? Typography.bodyEmphasized : Typography.body)
        let time = Self.label(Self.timeFormatter.localizedString(for: row.createdAt, relativeTo: now), font: Typography.caption)
        tinted = [(title, .primary), (time, .tertiary)]
        time.setContentCompressionResistancePriority(.required, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [title, time])
        header.spacing = Metrics.space2
        header.alignment = .firstBaseline

        var lines: [NSView] = [header]
        if let workspace = row.workspaceTitle {
            let label = Self.label(workspace, font: Typography.caption)
            tinted.append((label, .tertiary))
            lines.append(label)
        }
        if !row.body.isEmpty {
            let body = Self.label(row.body, font: Typography.body)
            tinted.append((body, .secondary))
            body.maximumNumberOfLines = 3
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
        self.close = close
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

    /// A one-line label; its owner sets the color in its theme scope.
    static func label(_ text: String, font: NSFont) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
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
