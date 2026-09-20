import AppKit

/// Native, wrapping Ports guidance hosted above the outline's passthrough SwiftUI row.
@MainActor
final class CloudPortsStatusContent: NSView {
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let actionButton = NSButton(title: "", target: nil, action: nil)
    private var presentation: CloudPortsStatusPresentation?
    private var style = CloudTreeStyle.defaultStyle
    private var actionHandler: (() -> Void)?

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !actionButton.isHidden, actionButton.frame.contains(point) else { return nil }
        return actionButton.hitTest(point)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.maximumNumberOfLines = 0
        titleLabel.lineBreakMode = .byWordWrapping
        messageLabel.maximumNumberOfLines = 0
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.textColor = .secondaryLabelColor
        actionButton.bezelStyle = .inline
        actionButton.target = self
        actionButton.action = #selector(performAction)
        actionButton.setAccessibilityRole(.button)
        addSubview(titleLabel)
        addSubview(messageLabel)
        addSubview(actionButton)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("CloudPortsStatus")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(
        presentation: CloudPortsStatusPresentation,
        style: CloudTreeStyle,
        action: @escaping () -> Void
    ) {
        self.presentation = presentation
        self.style = style
        actionHandler = action
        titleLabel.stringValue = presentation.title
        messageLabel.stringValue = presentation.message
        actionButton.title = presentation.actionTitle ?? ""
        actionButton.isHidden = presentation.action == .none || presentation.actionTitle == nil
        actionButton.setAccessibilityLabel(presentation.actionTitle ?? presentation.title)
        let fontSize = GlobalFontMagnification.scaledSize(max(10, style.detailSize))
        titleLabel.font = .systemFont(ofSize: fontSize, weight: .semibold)
        messageLabel.font = style.monospacedText
            ? .monospacedSystemFont(ofSize: fontSize, weight: .regular)
            : .systemFont(ofSize: fontSize)
        setAccessibilityLabel("\(presentation.title), \(presentation.message)")
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width = max(1, bounds.width)
        let inset: CGFloat = 2
        let titleHeight = Self.textHeight(titleLabel.stringValue, font: titleLabel.font ?? .systemFont(ofSize: 11), width: width - inset * 2)
        titleLabel.frame = NSRect(x: inset, y: 2, width: width - inset * 2, height: titleHeight)
        let messageY = titleLabel.frame.maxY + 2
        let messageHeight = Self.textHeight(messageLabel.stringValue, font: messageLabel.font ?? .systemFont(ofSize: 11), width: width - inset * 2)
        messageLabel.frame = NSRect(x: inset, y: messageY, width: width - inset * 2, height: messageHeight)
        if actionButton.isHidden {
            actionButton.frame = .zero
        } else {
            actionButton.frame = NSRect(x: inset, y: messageLabel.frame.maxY + 4, width: actionButton.fittingSize.width, height: 22)
        }
    }

    override var intrinsicContentSize: NSSize {
        guard let presentation else { return NSSize(width: NSView.noIntrinsicMetric, height: 0) }
        return NSSize(width: NSView.noIntrinsicMetric, height: Self.height(width: max(180, bounds.width), presentation: presentation, style: style))
    }

    static func height(width: CGFloat, presentation: CloudPortsStatusPresentation, style: CloudTreeStyle) -> CGFloat {
        let fontSize = GlobalFontMagnification.scaledSize(max(10, style.detailSize))
        let titleFont = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let messageFont = style.monospacedText
            ? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            : NSFont.systemFont(ofSize: fontSize)
        let contentWidth = max(1, width - 4)
        let title = textHeight(presentation.title, font: titleFont, width: contentWidth)
        let message = textHeight(presentation.message, font: messageFont, width: contentWidth)
        let button = presentation.action == .none ? 0 : 26
        return ceil(title + message + button + 10)
    }

    private static func textHeight(_ text: String, font: NSFont, width: CGFloat) -> CGFloat {
        ceil(NSAttributedString(string: text, attributes: [.font: font]).boundingRect(
            with: NSSize(width: max(1, width), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).height)
    }

    @objc private func performAction() { actionHandler?() }
}
