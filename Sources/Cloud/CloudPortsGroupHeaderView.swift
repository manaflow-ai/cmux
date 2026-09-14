import AppKit

/// Native Ports group header with an inline, accessible optional-VPN action.
@MainActor
final class CloudPortsGroupHeaderView: NSView {
    private let titleField = NSTextField(labelWithString: "")
    private let helpButton = CloudVPNSetupButton(frame: .zero, presentation: .helpIcon)
    private var style = CloudTreeStyle.defaultStyle

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleField.maximumNumberOfLines = 1
        titleField.lineBreakMode = .byTruncatingTail
        titleField.textColor = .secondaryLabelColor
        titleField.setAccessibilityIdentifier("CloudPortsGroupTitle")
        addSubview(titleField)
        addSubview(helpButton)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(style: CloudTreeStyle, setup: @escaping @MainActor (NSWindow?) -> Void) {
        self.style = style
        let title = String(localized: "cloudTree.group.ports", defaultValue: "Ports")
        let displayTitle = style.groupLabelStyle == .uppercased ? title.uppercased() : title
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.font(style: style),
            .foregroundColor: NSColor.secondaryLabelColor,
            .kern: style.groupLabelStyle == .uppercased ? 0.8 : 0
        ]
        titleField.attributedStringValue = NSAttributedString(string: displayTitle, attributes: attributes)
        helpButton.setup = setup
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let titleHeight = ceil(Self.font(style: style).boundingRectForFont.height)
        let titleWidth = min(titleField.attributedStringValue.size().width, max(0, bounds.width - 34))
        titleField.frame = NSRect(x: 0, y: floor((bounds.height - titleHeight) / 2), width: titleWidth, height: titleHeight)
        helpButton.frame = NSRect(x: titleField.frame.maxX + 5, y: floor((bounds.height - 24) / 2), width: 28, height: 24)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let buttonPoint = helpButton.convert(point, from: self)
        return helpButton.bounds.contains(buttonPoint) ? helpButton : nil
    }

    private static func font(style: CloudTreeStyle) -> NSFont {
        let size = GlobalFontMagnification.scaledSize(style.groupLabelSize)
        return style.monospacedText
            ? .monospacedSystemFont(ofSize: size, weight: .medium)
            : .systemFont(ofSize: size, weight: .medium)
    }
}
