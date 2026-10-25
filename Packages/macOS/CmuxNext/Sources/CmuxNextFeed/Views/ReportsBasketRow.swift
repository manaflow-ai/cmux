import AppKit
import CmuxNextDesign

/// One report in the Labs reports basket's list: the sender, when it arrived and the first lines of
/// its text. Takes the report as a value (no store below the list); a click calls `select`.
final class ReportsBasketRow: NSView {
    private(set) var item: FeedReport
    var selected = false { didSet { if selected != oldValue { paint() } } }
    private let select: () -> Void
    private var colors = ReportsBasketColors()
    private let icon = ReportsBasketText.symbol("arrow.down.message", size: TypeScale.detail)
    private let sender = ReportsBasketText.label(size: TypeScale.detail, weight: TypeScale.emphasis)
    private let time = ReportsBasketText.label(size: TypeScale.caption)
    private let body = ReportsBasketText.label(size: TypeScale.caption, lines: 2)

    init(item: FeedReport, select: @escaping () -> Void) {
        self.item = item
        self.select = select
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        translatesAutoresizingMaskIntoConstraints = false
        time.setContentCompressionResistancePriority(.required, for: .horizontal)
        time.setContentHuggingPriority(.required, for: .horizontal)
        let top = ReportsBasketText.stack([sender, time], vertical: false, spacing: 8, alignment: .firstBaseline)
        let text = ReportsBasketText.stack([top, body], spacing: 4)
        ReportsBasketText.flexible(text, .horizontal)
        let row = ReportsBasketText.stack([icon, text], vertical: false, spacing: 9, alignment: .top)
        row.edgeInsets = NSEdgeInsets(top: 8, left: 9, bottom: 8, right: 9)
        embed(row)
        NSLayoutConstraint.activate([
            top.widthAnchor.constraint(equalTo: text.widthAnchor),
            body.widthAnchor.constraint(equalTo: text.widthAnchor),
            icon.topAnchor.constraint(equalTo: text.topAnchor, constant: 2),
        ])
        setAccessibilityRole(.button)
        update(item)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows `item` (the same report, re-read from the model).
    func update(_ item: FeedReport) {
        self.item = item
        sender.stringValue = item.sender
        time.stringValue = item.createdAt.formatted(date: .omitted, time: .shortened)
        body.stringValue = item.body
        setAccessibilityLabel(item.sender)
    }

    func apply(_ colors: ReportsBasketColors) {
        self.colors = colors
        paint()
    }

    private func paint() {
        icon.contentTintColor = colors.secondary
        sender.textColor = colors.primary
        time.textColor = colors.tertiary
        body.textColor = colors.secondary
        layer?.backgroundColor = (selected ? colors.selection : .clear).cgColor
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { select() }
    }

    override func accessibilityPerformPress() -> Bool {
        select()
        return true
    }
}
