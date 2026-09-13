import AppKit
import CmuxFoundation

/// A fully wrapping, native callout. Its measured height also drives the outline row.
@MainActor
final class CloudPortsVPNEmptyStateContent: NSView {
    let setupButton = CloudTreeVPNSetupButton(frame: .zero)
    let explanationLabel = NSTextField(wrappingLabelWithString: "")
    private var style = CloudTreeStyle.defaultStyle

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(setupButton)
        addSubview(explanationLabel)
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
        setupButton.title = warning.setupTitle
        setupButton.setAccessibilityLabel(warning.setupTitle)
        setupButton.toolTip = warning.help
        setupButton.actionHandler = { [weak self] in setup(self?.window) }
        setupButton.font = Self.font(style: style)
        explanationLabel.attributedStringValue = Self.explanation(style: style)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width = max(1, bounds.width)
        setupButton.frame = NSRect(x: 0, y: 4, width: min(width, setupButton.fittingSize.width), height: 28)
        explanationLabel.frame = NSRect(x: 0, y: 38, width: width, height: Self.textHeight(width: width, style: style))
    }

    static func height(width: CGFloat, style: CloudTreeStyle) -> CGFloat {
        44 + textHeight(width: width, style: style)
    }

    private static func font(style: CloudTreeStyle) -> NSFont {
        let size = GlobalFontMagnification.scaledSize(max(11, style.detailSize))
        return style.monospacedText ? .monospacedSystemFont(ofSize: size, weight: .regular) : .systemFont(ofSize: size)
    }

    private static func explanation(style: CloudTreeStyle) -> NSAttributedString {
        NSAttributedString(string: CloudPortsVPNWarning().explanation, attributes: [.font: font(style: style)])
    }

    private static func textHeight(width: CGFloat, style: CloudTreeStyle) -> CGFloat {
        // NSTextField reserves horizontal cell insets, even for a wrapping label.
        ceil(explanation(style: style).boundingRect(
            with: NSSize(width: max(1, width - 4), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).height) + 4
    }
}
