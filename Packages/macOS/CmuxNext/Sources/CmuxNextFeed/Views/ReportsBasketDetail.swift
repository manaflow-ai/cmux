import AppKit
import CmuxNextDesign

/// The selected report in the Labs reports basket: its sender, when it arrived, its text, and a
/// reply field whose Reply button calls `onSend`. The basket owns the draft: the field reports each
/// edit through `onDraft` and the basket sets it back with ``setDraft(_:)``. `sending`: a reply is
/// in flight (the button waits for it); `notSent`: the last reply was not sent.
final class ReportsBasketDetail: NSView, NSTextFieldDelegate {
    private(set) var item: FeedReport
    private let onDraft: (String) -> Void
    private let onSend: () -> Void
    private var sending = false
    private let title = ReportsBasketText.label(size: TypeScale.title, weight: TypeScale.emphasis)
    private let from = ReportsBasketText.label(size: TypeScale.caption)
    private let text = ReportsBasketText.label(size: TypeScale.body, lines: 0)
    private let lines = [ReportsBasketHairline(), ReportsBasketHairline()]
    let notSentLabel = ReportsBasketText.label(FeedStrings.reportsNotSent, size: TypeScale.caption)
    private lazy var notSentRow = ReportsBasketText.stack([notSentLabel])
    let field = ReportsBasketReplyField()
    let replyButton = NSButton(title: FeedStrings.reportsReply, target: nil, action: nil)

    init(item: FeedReport, draft: String, onDraft: @escaping (String) -> Void, onSend: @escaping () -> Void) {
        self.item = item
        self.onDraft = onDraft
        self.onSend = onSend
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        field.placeholderString = FeedStrings.reportsReplyPlaceholder
        field.stringValue = draft
        field.delegate = self
        replyButton.bezelStyle = .push
        replyButton.keyEquivalent = ""
        replyButton.target = self
        replyButton.action = #selector(send)
        replyButton.setContentHuggingPriority(.required, for: .horizontal)
        replyButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        let header = ReportsBasketText.stack([title, from], spacing: 5, insets: 18)
        let body = ReportsBasketText.stack([text], insets: 18)
        let scroll = ReportsBasketText.scroll(body)
        notSentRow.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 0, right: 14)
        let reply = ReportsBasketText.stack([field, replyButton], vertical: false, spacing: 8, alignment: .bottom, insets: 14)
        let parts: [NSView] = [header, lines[0], scroll, lines[1], notSentRow, reply]
        let column = ReportsBasketText.stack(parts)
        embed(column)
        for part in parts { part.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        body.widthAnchor.constraint(equalTo: scroll.widthAnchor).isActive = true
        widthAnchor.constraint(greaterThanOrEqualToConstant: 420).isActive = true
        // The text scrolls; the header and the reply row keep their size.
        scroll.setContentHuggingPriority(.init(1), for: .vertical)
        scroll.setContentCompressionResistancePriority(.init(1), for: .vertical)
        update(item)
        setState(sending: false, notSent: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows `item` (the same report, re-read from the model).
    func update(_ item: FeedReport) {
        self.item = item
        title.stringValue = item.sender
        from.stringValue = FeedStrings.reportFrom(item.sender, item.createdAt.formatted(date: .long, time: .shortened))
        text.stringValue = item.body.isEmpty ? FeedStrings.reportsEmptyBody : item.body
    }

    /// The field shows `draft` (the basket emptied it after a sent reply or a new selection).
    func setDraft(_ draft: String) {
        if field.stringValue != draft { field.stringValue = draft }
        field.invalidateIntrinsicContentSize()
        updateButton()
    }

    func setState(sending: Bool, notSent: Bool) {
        self.sending = sending
        notSentRow.isHidden = !notSent
        updateButton()
    }

    func apply(_ colors: ReportsBasketColors) {
        title.textColor = colors.primary
        from.textColor = colors.tertiary
        text.textColor = colors.primary
        notSentLabel.textColor = colors.danger
        // The panel tints its controls with the text color (FeedRoot's `.tint`).
        replyButton.bezelColor = colors.primary
        lines.forEach { $0.apply(colors) }
    }

    private func updateButton() {
        replyButton.isEnabled = !sending && !field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func controlTextDidChange(_ obj: Notification) {
        field.invalidateIntrinsicContentSize()
        onDraft(field.stringValue)
        updateButton()
    }

    @objc private func send() {
        guard replyButton.isEnabled else { return }
        onSend()
    }
}

/// The reply field: rounded, wraps, and grows from one line to four.
final class ReportsBasketReplyField: NSTextField {
    init() {
        super.init(frame: .zero)
        isBezeled = true
        bezelStyle = .roundedBezel
        isEditable = true
        usesSingleLineMode = false
        cell?.wraps = true
        cell?.isScrollable = false
        lineBreakMode = .byWordWrapping
        font = .systemFont(ofSize: TypeScale.body)
        focusRingType = .none
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize {
        let one = super.intrinsicContentSize.height
        guard let cell, bounds.width > 0 else { return NSSize(width: NSView.noIntrinsicMetric, height: one) }
        let wrapped = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: bounds.width, height: .greatestFiniteMagnitude)).height
        let line = TypeScale.bodyLineHeight
        return NSSize(width: NSView.noIntrinsicMetric, height: min(max(wrapped, one), one + 3 * line))
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { invalidateIntrinsicContentSize() }
    }
}
