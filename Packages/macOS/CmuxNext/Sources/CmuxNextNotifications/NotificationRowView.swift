package import AppKit
package import CmuxNextDesign
import CmuxNextIcons

/// One notification in the panel: unread dot, title and time, the source
/// workspace, the body (two lines), and a dismiss button. A press opens it;
/// a right click shows the row's actions. The panel's list reuses a row for
/// another notification (`configure`), and the row lays itself out by hand
/// (`height(width:)` is the same layout), so the list measures and places
/// rows without an Auto Layout pass.
final class NotificationRowView: NSView {
    struct Callbacks {
        var open: () -> Void
        var dismiss: () -> Void
        var menu: () -> NSMenu
    }

    private(set) var row: NotificationsPanelRow
    var callbacks: Callbacks
    private let dot = NSView()
    private let title = NotificationsPanelStyle.label("", font: Typography.body)
    private let time = NotificationsPanelStyle.label("", font: Typography.caption)
    private let context = NotificationsPanelStyle.label("", font: Typography.caption)
    private let body = NotificationsPanelStyle.label("", font: Typography.body)
    private let close = NSButton(image: NSImage.icon(.actionClose, size: .iconFloor), target: nil, action: nil)
    /// Each label and the color it draws in, applied in the view's theme scope.
    private var tinted: [(ChromeLabel, NotificationsPanelStyle.Tone)] { [(title, .primary), (time, .tertiary), (context, .tertiary), (body, .secondary)] }
    var isSelected = false { didSet { if isSelected != oldValue { needsDisplay = true } } }

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
        layer?.cornerRadius = Metrics.insetCornerRadius // radius-allow: a list row nested in the panel, concentric with it
        layer?.cornerCurve = .continuous
        build()
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityIdentifier("cmux.notifications.row")
        apply(row, now: now)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    nonisolated override var wantsUpdateLayer: Bool { true }
    nonisolated override var isFlipped: Bool { true }

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
            close.contentTintColor = Palette.textTertiary
        }
        needsDisplay = true
    }

    private func build() {
        dot.wantsLayer = true
        dot.layer?.cornerRadius = Metrics.capsuleRadius(CGSize(width: Metrics.space2, height: Metrics.space2)) // radius-allow: the unread dot
        body.maximumNumberOfLines = 3
        body.lineBreakMode = .byTruncatingTail
        body.wraps = true
        close.target = self
        close.action = #selector(dismissPressed)
        close.setAccessibilityLabel(NotificationsPanelStrings.dismiss)
        close.isBordered = false
        close.setAccessibilityIdentifier("cmux.notifications.dismiss")
        for view in [dot, title, time, context, body, close] { addSubview(view) }
    }

    /// Shows `row`, its time relative to `now`; false when the row already showed exactly that.
    @discardableResult
    func configure(_ row: NotificationsPanelRow, now: Date) -> Bool {
        guard row != self.row || Self.timeText(row, now: now) != time.stringValue else { return false }
        apply(row, now: now)
        return true
    }

    private func apply(_ row: NotificationsPanelRow, now: Date) {
        self.row = row
        dot.isHidden = !row.unread
        title.stringValue = row.subtitle.map { "\(row.title) · \($0)" } ?? row.title
        title.font = row.unread ? Typography.bodyEmphasized : Typography.body
        time.stringValue = Self.timeText(row, now: now)
        let caption = [row.sourceLabel, row.workspaceTitle].compactMap { $0 }.joined(separator: " · ")
        context.stringValue = caption
        context.isHidden = caption.isEmpty
        body.stringValue = row.body
        body.isHidden = row.body.isEmpty
        setAccessibilityLabel([row.title, row.sourceLabel, row.workspaceTitle, row.body].compactMap { $0 }.joined(separator: ", "))
        needsLayout = true
    }

    private static func timeText(_ row: NotificationsPanelRow, now: Date) -> String {
        timeFormatter.localizedString(for: row.createdAt, relativeTo: now)
    }

    // MARK: Layout

    private static var inset: CGFloat { Metrics.space2 }
    private static var lineGap: CGFloat { Metrics.space1 / 2 }
    /// The text column's x: past the inset, the dot and a gap.
    private static var textX: CGFloat { 3 * Metrics.space2 }
    /// The text column's width in a row `width` wide: less the dot, the close button and the gaps.
    private static func textWidth(_ width: CGFloat) -> CGFloat { max(0, width - 5 * Metrics.space2 - Metrics.space6) }

    private struct Lines {
        var title: NSRect, time: NSRect, context: NSRect, body: NSRect
        var height: CGFloat
    }

    /// The frames of the text in a row `width` wide, and the row's height. A label's frame
    /// is its text plus the label's side padding, outside the text column.
    private func lines(width: CGFloat) -> Lines {
        let pad = title.alignmentRectInsets.left
        let textWidth = Self.textWidth(width), x = Self.textX - pad
        // Title and time share the first baseline; the time keeps its width, the title truncates.
        let timeSize = time.naturalSize, titleSize = title.naturalSize
        let baseline = max(title.firstBaselineOffsetFromTop, time.firstBaselineOffsetFromTop)
        let timeX = Self.textX + textWidth - timeSize.width + pad
        let titleWidth = max(0, min(titleSize.width, timeX + pad - Metrics.space2 - x))
        let titleFrame = NSRect(x: x, y: Self.inset + baseline - title.firstBaselineOffsetFromTop, width: titleWidth, height: titleSize.height)
        let timeFrame = NSRect(x: timeX, y: Self.inset + baseline - time.firstBaselineOffsetFromTop, width: timeSize.width, height: timeSize.height)
        var bottom = max(titleFrame.maxY, timeFrame.maxY)
        var contextFrame = NSRect.zero, bodyFrame = NSRect.zero
        if !context.isHidden {
            let size = context.naturalSize
            contextFrame = NSRect(x: x, y: bottom + Self.lineGap, width: min(size.width, textWidth + 2 * pad), height: size.height)
            bottom = contextFrame.maxY
        }
        if !body.isHidden {
            let height = body.size(forWidth: textWidth + 2 * pad).height
            bodyFrame = NSRect(x: x, y: bottom + Self.lineGap, width: textWidth + 2 * pad, height: height)
            bottom = bodyFrame.maxY
        }
        return Lines(title: titleFrame, time: timeFrame, context: contextFrame, body: bodyFrame, height: ceil(bottom + Self.inset))
    }

    /// The row's height at `width` for what it shows now: a text measure, no layout pass.
    func height(width: CGFloat) -> CGFloat { lines(width: width).height }

    override func layout() {
        super.layout()
        let lines = lines(width: bounds.width)
        title.frame = lines.title
        time.frame = lines.time
        context.frame = lines.context
        body.frame = lines.body
        let side = Metrics.space2
        dot.frame = NSRect(x: Self.inset, y: lines.title.midY - side / 2, width: side, height: side)
        let closeHeight = max(close.intrinsicContentSize.height, Metrics.space6)
        close.frame = NSRect(x: bounds.width - Self.inset - Metrics.space6, y: lines.title.midY - closeHeight / 2,
                             width: Metrics.space6, height: closeHeight)
    }

    @objc private func dismissPressed() { callbacks.dismiss() }

    /// A click opens the notification on the press (Lawrence 2026-10-19: "mouse down to immediately
    /// open"); a Control-click goes to AppKit, which shows the row's menu.
    override func mouseDown(with event: NSEvent) {
        guard !event.modifierFlags.contains(.control) else { return super.mouseDown(with: event) }
        callbacks.open()
    }

    /// The press already opened it.
    override func mouseUp(with event: NSEvent) {}

    override func menu(for event: NSEvent) -> NSMenu? { NSMenu.withoutSystemItems(callbacks.menu()) }

    override func accessibilityPerformPress() -> Bool {
        callbacks.open()
        return true
    }
}

/// The panel's text: its labels and the colors they draw in.
package struct NotificationsPanelStyle {
    package init() {}
    /// The text colors the panel uses.
    package enum Tone {
        case primary, secondary, tertiary

        /// theme-scoped: read inside `performWithTheme`.
        package var color: NSColor {
            switch self {
            case .primary: Palette.textPrimary
            case .secondary: Palette.textSecondary
            case .tertiary: Palette.textTertiary
            }
        }
    }

    /// A one-line label; its owner sets the color in its theme scope.
    package static func label(_ text: String, font: NSFont) -> ChromeLabel {
        let label = ChromeLabel(labelWithString: text)
        label.font = font
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        return label
    }
}
