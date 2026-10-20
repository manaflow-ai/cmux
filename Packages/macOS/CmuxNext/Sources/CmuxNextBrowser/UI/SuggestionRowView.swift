import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// One suggestion: 16 pt icon, then "title – detail" on one line with the
/// detail dimmed ("query - Engine Search"). The one highlighted row
/// (keyboard or mouse, the state machine decides) gets a rounded gray fill
/// concentric with the card (`OmnibarStyle.rowCornerRadius`). The row itself only reports the pointer and clicks.
final class SuggestionRowView: NSView {
    var onClick: ((NSEvent.ModifierFlags) -> Void)?
    /// Pointer inside (true) or leaving (false), at a screen point.
    var onPointer: ((Bool, CGPoint) -> Void)?
    var isHighlighted = false {
        didSet {
            guard oldValue != isHighlighted else { return }
            setAccessibilitySelected(isHighlighted)
            updateFill()
        }
    }
    var leadingIconCenter: CGFloat = 16 { didSet { needsLayout = true } }
    var textLeading: CGFloat = 33 { didSet { needsLayout = true } }

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var tracking: NSTrackingArea?
    private var title = ""
    private var detail = ""
    private var iconKind: IconName?
    /// The match shown now.
    private(set) var suggestion: BrowserSuggestion

    init(suggestion: BrowserSuggestion) {
        self.suggestion = suggestion
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        icon.imageScaling = .scaleNone
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        addSubview(icon)
        addSubview(label)

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilitySelected(false)
        show(suggestion, force: true)
    }

    /// Shows `suggestion` in this row, in place (Chromium
    /// `OmniboxResultView::SetMatch`): typing changes the rows' text, it
    /// never tears the card's views down. Touches only what changed.
    func show(_ suggestion: BrowserSuggestion, force: Bool = false) {
        guard force || suggestion != self.suggestion else { return }
        self.suggestion = suggestion
        let kind: IconName = switch suggestion.kind {
        case .navigate: .browser
        case .search: .search
        case .history: .history
        case .bookmark: .bookmark
        case .keyword: .extension
        case .switchToTab: .omnibarSwitchtab
        case .answer: .omnibarAnswer
        }
        if kind != iconKind {
            iconKind = kind
            icon.image = NSImage.icon(kind, size: .iconRowSize(forLabelPointSize: OmnibarStyle.iconPointSize))
        }
        setAccessibilityLabel([suggestion.title, suggestion.detail].filter { !$0.isEmpty }.joined(separator: ", "))
        guard force || suggestion.title != title || suggestion.detail != detail else { return }
        title = suggestion.title
        detail = suggestion.detail
        applyColors()
        needsLayout = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        layer?.cornerRadius = OmnibarStyle.rowCornerRadius
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
