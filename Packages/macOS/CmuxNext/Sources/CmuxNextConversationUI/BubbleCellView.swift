import AppKit
import CmuxConversation

/// One transcript row: a bubble with optional files, a status line, answer
/// buttons, and (for a queued message) a remove button shown on hover.
final class BubbleCellView: NSTableCellView {
    private let body = NSTextField(wrappingLabelWithString: "")
    private let files = NSTextField(wrappingLabelWithString: "")
    private let status = NSButton(title: "", target: nil, action: nil)
    private let answers = NSStackView()
    private let remove = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil) ?? NSImage(), target: nil, action: nil)
    private let column = NSStackView()
    private var tracking: NSTrackingArea?
    private var row: TranscriptRow?
    var onRemove: ((ClientMessageID) -> Void)?
    var onRetry: ((ClientMessageID) -> Void)?
    var onAnswer: ((String, String) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        body.isSelectable = true
        body.wantsLayer = true
        body.layer?.cornerRadius = 10
        body.drawsBackground = true
        files.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        files.textColor = .secondaryLabelColor
        status.isBordered = false
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.contentTintColor = .secondaryLabelColor
        status.target = self
        status.action = #selector(statusClicked)
        remove.isBordered = false
        remove.isHidden = true
        remove.target = self
        remove.action = #selector(removeClicked)
        answers.orientation = .horizontal
        answers.spacing = 6
        column.orientation = .vertical
        column.spacing = 3
        column.setViews([body, files, answers, status], in: .top)
        column.translatesAutoresizingMaskIntoConstraints = false
        remove.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        addSubview(remove)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 30),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            remove.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            remove.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            body.widthAnchor.constraint(lessThanOrEqualTo: column.widthAnchor, multiplier: 0.8),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(_ row: TranscriptRow) {
        self.row = row
        body.stringValue = row.text
        let user = row.style == .user
        column.alignment = user ? .trailing : .leading
        body.alignment = .left
        switch row.style {
        case .user:
            body.backgroundColor = .quaternaryLabelColor
            body.textColor = .labelColor
        case .assistant:
            body.backgroundColor = .clear
            body.textColor = .labelColor
        case .reasoning, .activity, .notice:
            body.backgroundColor = .clear
            body.textColor = .secondaryLabelColor
        case .approval:
            body.backgroundColor = .quaternaryLabelColor
            body.textColor = .labelColor
        case .error:
            body.backgroundColor = .clear
            body.textColor = .systemRed
        case .separator:
            body.backgroundColor = .clear
        }
        body.font = row.style == .reasoning ? .systemFont(ofSize: NSFont.systemFontSize).italic() : .systemFont(ofSize: NSFont.systemFontSize)
        files.isHidden = row.files.isEmpty
        files.stringValue = row.files.map(\.1).joined(separator: "\n")
        files.textColor = row.files.contains { $0.2 } ? .systemRed : .secondaryLabelColor
        status.isHidden = row.status == nil
        status.title = row.status ?? ""
        status.contentTintColor = row.delivery == .failed ? .systemRed : .secondaryLabelColor
        answers.setViews([], in: .leading)
        if let approval = row.approval, approval.isPending {
            for option in approval.options {
                let b = NSButton(title: option.label, target: self, action: #selector(answerClicked(_:)))
                b.identifier = NSUserInterfaceItemIdentifier(option.id)
                answers.addView(b, in: .leading)
            }
        }
        answers.isHidden = answers.views.isEmpty
        remove.isHidden = true
    }

    private var isQueued: Bool {
        if case .queued? = row?.delivery { return true }
        return row?.delivery == .uploading
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { remove.isHidden = !isQueued }
    override func mouseExited(with event: NSEvent) { remove.isHidden = true }

    @objc private func removeClicked() {
        if let id = row?.clientMessageID { onRemove?(id) }
    }

    @objc private func statusClicked() {
        if row?.delivery == .failed, let id = row?.clientMessageID { onRetry?(id) }
    }

    @objc private func answerClicked(_ sender: NSButton) {
        if let id = row?.approval?.id, let option = sender.identifier?.rawValue { onAnswer?(id, option) }
    }
}

private extension NSFont {
    func italic() -> NSFont {
        NSFontManager.shared.convert(self, toHaveTrait: .italicFontMask)
    }
}
