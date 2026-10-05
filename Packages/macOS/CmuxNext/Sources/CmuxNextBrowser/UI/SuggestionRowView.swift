import AppKit
import CmuxNextDesign

/// One suggestion: 16 pt icon, then "title – detail" on one line with the
/// detail dimmed ("query - Engine Search"). The one highlighted row
/// (keyboard or mouse, the state machine decides) gets an 8 pt rounded gray
/// fill. The row itself only reports the pointer and clicks.
final class SuggestionRowView: NSView {
    var onClick: ((NSEvent.ModifierFlags) -> Void)?
    /// Pointer inside (true) or leaving (false), at a screen point.
    var onPointer: ((Bool, CGPoint) -> Void)?
    var isHighlighted = false { didSet { if oldValue != isHighlighted { updateFill() } } }
    var leadingIconCenter: CGFloat = 16 { didSet { needsLayout = true } }
    var textLeading: CGFloat = 33 { didSet { needsLayout = true } }

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var tracking: NSTrackingArea?
    private let title: String
    private let detail: String

    init(suggestion: BrowserSuggestion) {
        title = suggestion.title
        detail = suggestion.detail
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = OmnibarStyle.rowCornerRadius
        layer?.cornerCurve = .continuous

        let symbol = switch suggestion.kind {
        case .navigate: "globe"
        case .search: "magnifyingglass"
        case .history: "clock"
        case .bookmark: "star"
        case .keyword: "puzzlepiece.extension"
        case .switchToTab: "rectangle.on.rectangle"
        }
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: OmnibarStyle.iconPointSize, weight: .regular))
        icon.imageScaling = .scaleNone
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        addSubview(icon)
        addSubview(label)

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel([suggestion.title, suggestion.detail].filter { !$0.isEmpty }.joined(separator: ", "))
        applyColors()
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
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { onPointer?(true, screenPoint(event)) }
    override func mouseMoved(with event: NSEvent) { onPointer?(true, screenPoint(event)) }
    override func mouseExited(with event: NSEvent) { onPointer?(false, screenPoint(event)) }
    override func mouseUp(with event: NSEvent) { onClick?(event.modifierFlags) }
    override func mouseDown(with event: NSEvent) {}
    override func accessibilityPerformPress() -> Bool { onClick?([]); return true }

    /// The event's location on screen. A tracking event is delivered to this
    /// row's window, so convert through it; `event.window` is nil when the
    /// event carries no window number (a window that has none yet).
    private func screenPoint(_ event: NSEvent) -> CGPoint {
        (event.window ?? window)?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColors()
    }

    private func applyColors() {
        performWithTheme {
            icon.contentTintColor = OmnibarStyle.textSecondary
            let text = NSMutableAttributedString(string: title, attributes: [
                .font: OmnibarStyle.font,
                .foregroundColor: OmnibarStyle.textPrimary,
            ])
            if !detail.isEmpty {
                text.append(NSAttributedString(string: " – " + detail, attributes: [
                    .font: OmnibarStyle.rowDetailFont,
                    .foregroundColor: OmnibarStyle.textSecondary,
                ]))
            }
            label.attributedStringValue = text
        }
        updateFill()
    }

    private func updateFill() {
        performWithTheme {
            layer?.backgroundColor = (isHighlighted ? OmnibarStyle.rowSelectedFill : .clear).cgColor
        }
    }
}
