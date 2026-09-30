import AppKit
import CmuxNextDesign

/// One suggestion: 16 pt icon, then "title – detail" on one line with the
/// detail dimmed (Helium: "query - Engine Search"). Selected and hovered rows
/// get an 8 pt rounded gray fill.
final class SuggestionRowView: NSView {
    var onClick: (() -> Void)?
    var isSelected = false { didSet { if oldValue != isSelected { updateFill() } } }
    /// Hover only draws; it never changes the selection or the field text.
    private var isHovering = false { didSet { if oldValue != isHovering { updateFill() } } }
    var leadingIconCenter: CGFloat = 16 { didSet { needsLayout = true } }
    var textLeading: CGFloat = 33 { didSet { needsLayout = true } }

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var tracking: NSTrackingArea?

    init(suggestion: BrowserSuggestion) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = OmnibarStyle.rowCornerRadius
        layer?.cornerCurve = .continuous

        let symbol = switch suggestion.kind {
        case .navigate: "globe"
        case .search: "magnifyingglass"
        case .history: "clock"
        }
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: OmnibarStyle.iconPointSize, weight: .regular))
        icon.contentTintColor = OmnibarStyle.textSecondary
        icon.imageScaling = .scaleNone

        let text = NSMutableAttributedString(string: suggestion.title, attributes: [
            .font: OmnibarStyle.font,
            .foregroundColor: OmnibarStyle.textPrimary,
        ])
        if !suggestion.detail.isEmpty {
            text.append(NSAttributedString(string: " – " + suggestion.detail, attributes: [
                .font: OmnibarStyle.rowDetailFont,
                .foregroundColor: OmnibarStyle.textSecondary,
            ]))
        }
        label.attributedStringValue = text
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        addSubview(icon)
        addSubview(label)

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel([suggestion.title, suggestion.detail].filter { !$0.isEmpty }.joined(separator: ", "))
        updateFill()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        let side: CGFloat = 16
        icon.frame = NSRect(x: (leadingIconCenter - side / 2).rounded(), y: ((bounds.height - side) / 2).rounded(), width: side, height: side)
        let height = label.intrinsicContentSize.height
        label.frame = NSRect(
            x: textLeading,
            y: ((bounds.height - height) / 2).rounded(),
            width: max(0, bounds.width - textLeading - OmnibarStyle.trailingPadding),
            height: height
        )
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }
    override func mouseUp(with event: NSEvent) { onClick?() }
    override func mouseDown(with event: NSEvent) {}
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateFill()
    }

    private func updateFill() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (isSelected || isHovering ? OmnibarStyle.rowSelectedFill : .clear).cgColor
        }
    }
}
