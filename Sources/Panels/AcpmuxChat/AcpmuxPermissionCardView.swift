import AppKit
import CmuxAcpmux

/// The approval card that slides in above the composer while a permission request waits.
@MainActor
final class AcpmuxPermissionCardView: AcpmuxFlippedView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private var buttons: [NSButton] = []
    private(set) var card: TranscriptPermissionCard?
    var onChoose: ((TranscriptPermissionCard, String?) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        titleLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        detailLabel.maximumNumberOfLines = 3
        addSubview(titleLabel)
        addSubview(detailLabel)
        setAccessibilityIdentifier("acpmuxChat.permissionCard")
    }

    func update(_ card: TranscriptPermissionCard, theme: AcpmuxChatTheme) {
        layer?.backgroundColor = theme.surface.cgColor
        layer?.borderColor = theme.accent.withAlphaComponent(0.45).cgColor
        titleLabel.textColor = theme.foreground
        detailLabel.textColor = theme.secondaryText
        guard card != self.card else { return }
        self.card = card
        let format = String(localized: "acpmuxChat.permission.prompt", defaultValue: "Allow %@?")
        // Titles often end in "?" already ("may I edit the file?"); the format adds its own.
        var title = card.request.toolCall?.title ?? String(localized: "acpmuxChat.permission.fallbackTitle", defaultValue: "Tool call")
        while let last = title.last, last == "?" || last == "？" { title.removeLast() }
        titleLabel.stringValue = String.localizedStringWithFormat(format, title)
        let input = card.request.toolCall?.rawInput
        detailLabel.stringValue = input?["command"]?.stringValue
            ?? input?["file_path"]?.stringValue
            ?? input.map { String($0.compactText.prefix(240)) }
            ?? ""
        buttons.forEach { $0.removeFromSuperview() }
        buttons = card.request.options.map { option in
            let button = NSButton(title: option.name, target: self, action: #selector(choose(_:)))
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.identifier = NSUserInterfaceItemIdentifier(option.optionId)
            addSubview(button)
            return button
        }
        if buttons.isEmpty {
            let dismiss = NSButton(
                title: String(localized: "acpmuxChat.permission.dismiss", defaultValue: "Dismiss"),
                target: self,
                action: #selector(choose(_:))
            )
            dismiss.bezelStyle = .rounded
            dismiss.controlSize = .small
            addSubview(dismiss)
            buttons = [dismiss]
        }
        needsLayout = true
    }

    var preferredHeight: CGFloat {
        detailLabel.stringValue.isEmpty ? 64 : 96
    }

    override func layout() {
        super.layout()
        titleLabel.frame = CGRect(x: 12, y: 10, width: bounds.width - 24, height: 17)
        detailLabel.frame = CGRect(x: 12, y: 30, width: bounds.width - 24, height: detailLabel.stringValue.isEmpty ? 0 : 30)
        var x = bounds.width - 12
        for button in buttons.reversed() {
            button.sizeToFit()
            x -= button.frame.width
            button.frame.origin = CGPoint(x: x, y: bounds.height - button.frame.height - 9)
            x -= 8
        }
    }

    @objc private func choose(_ sender: NSButton) {
        guard let card else { return }
        onChoose?(card, sender.identifier?.rawValue)
    }
}
