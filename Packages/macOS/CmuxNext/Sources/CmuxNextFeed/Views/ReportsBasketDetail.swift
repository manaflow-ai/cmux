import AppKit
import CmuxNextDesign

/// The selected report in the reports basket: its sender, when it arrived, its text, and a
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
    private lazy var fieldHeight = field.heightAnchor.constraint(equalToConstant: 22)
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
        // Labels wrap (or truncate) inside their pane instead of keeping their one-line width.
        for label in [title, from] { label.widthAnchor.constraint(equalTo: header.widthAnchor, constant: -36).isActive = true }
        text.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -36).isActive = true
        notSentLabel.widthAnchor.constraint(equalTo: notSentRow.widthAnchor, constant: -28).isActive = true
        widthAnchor.constraint(greaterThanOrEqualToConstant: 420).isActive = true
        fieldHeight.isActive = true
        // The text scrolls; the header and the reply row keep their size.
        ReportsBasketText.flexible(scroll, .vertical)
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
        sizeField()
        updateButton()
    }

    /// Fits the reply field to its text at its width (one line to four).
    private func sizeField() {
        let height = field.height(forWidth: field.frame.width)
        if height > 0, abs(fieldHeight.constant - height) > 0.5 { fieldHeight.constant = height }
    }

    override func layout() {
        super.layout()
        sizeField()
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
        sizeField()
        onDraft(field.stringValue)
        updateButton()
    }

    @objc private func send() {
        guard replyButton.isEnabled else { return }
        onSend()
    }
}

/// The reply field: rounded, wraps, and grows from one line to four (``ReportsBasketDetail`` sets
/// its height from ``height(forWidth:)``; the field overrides nothing).
final class ReportsBasketReplyField: NSTextField {
    static let maxLines = 4

    init() {
        super.init(frame: .zero)
        isBezeled = true
        bezelStyle = .roundedBezel
        isEditable = true
        usesSingleLineMode = false
        cell?.wraps = true
        cell?.isScrollable = false
        lineBreakMode = .byWordWrapping
        maximumNumberOfLines = Self.maxLines
        font = .systemFont(ofSize: TypeScale.body)
        focusRingType = .none
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The height that shows the text at `width`: one line to four.
    func height(forWidth width: CGFloat) -> CGFloat {
        guard let cell, width > 0 else { return 0 }
        // While editing, the text is the field editor's (the cell has the value from before the edit).
        let probe = cell.copy() as? NSCell ?? cell
        probe.stringValue = (currentEditor() as? NSTextView)?.string ?? stringValue
        let tall = NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)
        let wrapped = probe.cellSize(forBounds: tall).height
        probe.stringValue = "X"
        let one = probe.cellSize(forBounds: tall).height
        return min(max(wrapped, one), one + CGFloat(Self.maxLines - 1) * TypeScale.bodyLineHeight)
    }
}
