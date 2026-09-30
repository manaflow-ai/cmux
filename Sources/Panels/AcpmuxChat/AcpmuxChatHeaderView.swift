import AppKit
import CmuxAcpmux

/// The pane header: a session picker menu and the session status.
@MainActor
final class AcpmuxChatHeaderView: AcpmuxFlippedView {
    let pickerButton = AcpmuxChipButton()
    private let statusDot = CALayer()
    private let statusLabel = NSTextField(labelWithString: "")
    private let divider = CALayer()

    static let height: CGFloat = 34

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        pickerButton.setAccessibilityIdentifier("acpmuxChat.sessionPicker")
        addSubview(pickerButton)
        statusDot.cornerRadius = 3.5
        layer?.addSublayer(statusDot)
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.lineBreakMode = .byTruncatingTail
        addSubview(statusLabel)
        layer?.addSublayer(divider)
    }

    func update(title: String, status: String, statusColor: NSColor, theme: AcpmuxChatTheme) {
        pickerButton.apply(title: title, theme: theme)
        pickerButton.layer?.backgroundColor = NSColor.clear.cgColor
        pickerButton.attributedTitle = NSAttributedString(string: "\(title) \u{25BE}", attributes: [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold),
            .foregroundColor: theme.foreground,
        ])
        statusLabel.stringValue = status
        statusLabel.textColor = theme.secondaryText
        statusDot.backgroundColor = statusColor.cgColor
        divider.backgroundColor = theme.border.cgColor
        needsLayout = true
    }

    override func layout() {
        super.layout()
        statusLabel.sizeToFit()
        let labelWidth = min(statusLabel.frame.width, bounds.width * 0.4)
        statusLabel.frame = CGRect(x: bounds.width - 14 - labelWidth, y: (bounds.height - statusLabel.frame.height) / 2,
                                   width: labelWidth, height: statusLabel.frame.height)
        statusDot.frame = CGRect(x: statusLabel.frame.minX - 12, y: bounds.height / 2 - 3.5, width: 7, height: 7)
        let pickerWidth = min(pickerButton.frame.width, statusDot.frame.minX - 20)
        pickerButton.frame = CGRect(x: 8, y: (bounds.height - 22) / 2, width: max(60, pickerWidth), height: 22)
        divider.frame = CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
    }
}
