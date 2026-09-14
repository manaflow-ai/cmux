import AppKit
import CmuxFoundation

/// A fully wrapping, native callout. Its measured height also drives the outline row.
@MainActor
final class CloudPortsVPNEmptyStateContent: NSView {
    let titleLabel = NSTextField(labelWithString: "")
    let setupButton = CloudVPNSetupButton(frame: .zero, presentation: .text)
    let explanationLabel = NSTextField(wrappingLabelWithString: "")
    private var style = CloudTreeStyle.defaultStyle

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(titleLabel)
        addSubview(setupButton)
        addSubview(explanationLabel)
        titleLabel.setAccessibilityIdentifier("CloudPortsVPNTitle")
        titleLabel.maximumNumberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.textColor = .labelColor
        explanationLabel.maximumNumberOfLines = 0
        explanationLabel.textColor = .secondaryLabelColor
        explanationLabel.setAccessibilityIdentifier("CloudPortsVPNExplanation")
        setAccessibilityIdentifier("CloudPortsVPNEmptyState")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(style: CloudTreeStyle, setup: @escaping @MainActor (NSWindow?) -> Void) {
        self.style = style
        let warning = CloudPortsVPNWarning()
        setupButton.setup = setup
        setupButton.title = warning.actionTitle
        setupButton.font = Self.actionFont(style: style)
        setupButton.setAccessibilityLabel(warning.setupTitle)
        setupButton.toolTip = warning.help
        titleLabel.attributedStringValue = Self.title(style: style)
        explanationLabel.attributedStringValue = Self.explanation(style: style)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width = max(1, bounds.width)
        let titleHeight = Self.titleHeight(style: style)
        titleLabel.frame = NSRect(x: 0, y: 5, width: width, height: titleHeight)
        let bodyY = titleLabel.frame.maxY + 3
        let bodyHeight = Self.textHeight(width: width, style: style)
        explanationLabel.frame = NSRect(x: 0, y: bodyY, width: width, height: bodyHeight)
        let actionY = explanationLabel.frame.maxY + 4
        setupButton.frame = NSRect(x: 0, y: actionY, width: min(width, setupButton.fittingSize.width), height: 22)
    }

    static func height(width: CGFloat, style: CloudTreeStyle) -> CGFloat {
        5 + titleHeight(style: style) + 3 + textHeight(width: width, style: style) + 4 + 22 + 4
    }

    private static func bodyFont(style: CloudTreeStyle) -> NSFont {
        let size = GlobalFontMagnification.scaledSize(max(11, style.detailSize))
        return style.monospacedText ? .monospacedSystemFont(ofSize: size, weight: .regular) : .systemFont(ofSize: size)
    }

    private static func titleFont(style: CloudTreeStyle) -> NSFont {
        let size = GlobalFontMagnification.scaledSize(max(11, style.detailSize))
        return style.monospacedText ? .monospacedSystemFont(ofSize: size, weight: .semibold) : .systemFont(ofSize: size, weight: .semibold)
    }

    private static func actionFont(style: CloudTreeStyle) -> NSFont {
        let size = GlobalFontMagnification.scaledSize(max(11, style.detailSize))
        return .systemFont(ofSize: size, weight: .medium)
    }

    private static func title(style: CloudTreeStyle) -> NSAttributedString {
        NSAttributedString(string: CloudPortsVPNWarning().title, attributes: [.font: titleFont(style: style)])
    }

    private static func titleHeight(style: CloudTreeStyle) -> CGFloat {
        ceil(titleFont(style: style).boundingRectForFont.height)
    }

    private static func explanation(style: CloudTreeStyle) -> NSAttributedString {
        NSAttributedString(string: CloudPortsVPNWarning().explanation, attributes: [.font: bodyFont(style: style)])
    }

    private static func textHeight(width: CGFloat, style: CloudTreeStyle) -> CGFloat {
        // NSTextField reserves horizontal cell insets, even for a wrapping label.
        ceil(explanation(style: style).boundingRect(
            with: NSSize(width: max(1, width - 4), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).height) + 4
    }
}
