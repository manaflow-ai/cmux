import AppKit
import CmuxCloud
import CmuxFoundation
import CmuxSurfaceCatalogModel

/// Native, wrapping Ports guidance hosted above the outline's passthrough SwiftUI row.
@MainActor
final class CloudPortsStatusContent: NSView {
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let actionButton = CloudPortsStatusActionButton()
    private var presentation: CloudPortsStatusPresentation?
    private var style = CloudTreeStyle.defaultStyle
    private var actionHandler: (() -> Void)?

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // AppKit receives points in the receiver's superview; let its implementation own conversion.
        guard let hit = super.hitTest(point), hit === actionButton || hit.isDescendant(of: actionButton) else { return nil }
        return hit
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.maximumNumberOfLines = 0
        titleLabel.lineBreakMode = .byWordWrapping
        messageLabel.maximumNumberOfLines = 0
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.textColor = .secondaryLabelColor
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
        actionButton.setTitle(presentation.actionTitle ?? "", fontSize: GlobalFontMagnification.scaledSize(max(10, style.detailSize)))
        actionButton.isHidden = presentation.action == .none || presentation.actionTitle == nil
        actionButton.setAccessibilityLabel(presentation.actionTitle ?? presentation.title)
        let fontSize = GlobalFontMagnification.scaledSize(max(10, style.detailSize))
        titleLabel.font = .systemFont(ofSize: fontSize, weight: .semibold)
        messageLabel.font = style.monospacedText
            ? .monospacedSystemFont(ofSize: fontSize, weight: .regular)
            : .systemFont(ofSize: fontSize)
        setAccessibilityLabel("\(presentation.title), \(presentation.message)")
        invalidateIntrinsicContentSize()
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
            // The button hugs its title; give it room on both sides.
            let padding = GlobalFontMagnification.scaledSize(Self.actionHorizontalPadding) * 2
            actionButton.frame = NSRect(x: inset, y: messageLabel.frame.maxY + 4, width: min(width - inset * 2, actionButton.fittingSize.width + padding), height: 22)
        }
    }

    private static let actionHorizontalPadding: CGFloat = 10

    override var intrinsicContentSize: NSSize {
        guard let presentation else { return NSSize(width: NSView.noIntrinsicMetric, height: 0) }
        return NSSize(width: NSView.noIntrinsicMetric, height: Self.height(width: max(1, bounds.width), presentation: presentation, style: style))
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
        let button: CGFloat = presentation.action == .none ? 0 : 26
        return ceil(title + message + button + 10)
    }

    /// Measures with the same wrapping label cell that draws the text. A string's
    /// bounding rect uses the font's 13 pt line height at 11 pt, while the cell
    /// draws 14 pt lines, so a bounding-rect row drops its last wrapped line.
    private static let measuringLabel: NSTextField = {
        let label = NSTextField(wrappingLabelWithString: "")
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        return label
    }()

    private static func textHeight(_ text: String, font: NSFont, width: CGFloat) -> CGFloat {
        measuringLabel.font = font
        measuringLabel.stringValue = text
        let bounds = NSRect(x: 0, y: 0, width: max(1, width), height: .greatestFiniteMagnitude)
        return ceil(measuringLabel.cell?.cellSize(forBounds: bounds).height ?? 0)
    }

    @objc private func performAction() { actionHandler?() }
}

/// The Ports status action ("Refresh", "Set Up VPN…"): a quiet rounded chip
/// in the Cloud tree's shape and fills (`CloudTreeHoverStyle`). Its title
/// brightens and its fill deepens under the pointer, and again while pressed.
@MainActor
final class CloudPortsStatusActionButton: NSButton {
    private var isHovered = false { didSet { if isHovered != oldValue { refreshAppearance() } } }
    private var hoverTracking: NSTrackingArea?
    private var chipTitle = ""
    private static let restFill = CloudTreeHoverStyle.selectedOpacity
    private static let hoverFill = CloudTreeHoverStyle.selectedOpacity + CloudTreeHoverStyle.hoverOpacity
    private static let pressedFill = CloudTreeHoverStyle.selectedOpacity + CloudTreeHoverStyle.pressedOpacity
    private var fontSize: CGFloat = 11

    init() {
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = CloudTreeHoverStyle.cornerRadius
        layer?.cornerCurve = .continuous
        setButtonType(.momentaryChange)
        refreshAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setTitle(_ title: String, fontSize: CGFloat) {
        chipTitle = title
        self.fontSize = fontSize
        refreshAppearance()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override var isHighlighted: Bool {
        didSet { refreshAppearance() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearance()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { isHovered = false }
    }

    private func refreshAppearance() {
        let opacity = isHighlighted ? Self.pressedFill : (isHovered ? Self.hoverFill : Self.restFill)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(opacity).cgColor
        }
        attributedTitle = NSAttributedString(string: chipTitle, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: isHovered || isHighlighted ? NSColor.labelColor : NSColor.secondaryLabelColor,
        ])
    }
}
