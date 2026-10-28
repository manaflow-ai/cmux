import AppKit
public import CmuxNextDesignTokens

/// A find pill's round button: borderless, ``FindPillMetrics/buttonSize`` square, with a
/// circular hover fill (and the accent tint while a toggle is on), the way Safari's find
/// buttons look on macOS 26.
final class FindPillButton: NSButton {
    private var hovering = false {
        didSet { if hovering != oldValue { applyColors() } }
    }
    private var tracking: NSTrackingArea?

    init(image: NSImage?, title: String = "", toggle: Bool = false, target: AnyObject?, action: Selector) {
        super.init(frame: .zero)
        self.image = image
        self.title = title
        self.target = target
        self.action = action
        imagePosition = image == nil ? .noImage : .imageOnly
        if toggle { setButtonType(.pushOnPushOff) }
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = FindPillMetrics.buttonSize / 2
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: FindPillMetrics.buttonSize),
            widthAnchor.constraint(greaterThanOrEqualToConstant: FindPillMetrics.buttonSize),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var state: NSControl.StateValue {
        didSet { applyColors() }
    }

    override var isEnabled: Bool {
        didSet { applyColors() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColors()
    }

    /// Re-reads the theme's inks: secondary at rest, primary under the pointer, the lit glyph while on.
    func applyColors() {
        performWithTheme {
            let on = state == .on
            let ink = on ? Palette.litGlyph : (hovering && isEnabled ? Palette.textPrimary : Palette.textSecondary)
            contentTintColor = ink
            if !title.isEmpty {
                attributedTitle = NSAttributedString(string: title, attributes: [
                    .font: Typography.system(.default, size: TypeScale.caption, weight: .semibold),
                    .foregroundColor: ink,
                ])
            }
            let fill: NSColor = on ? Palette.accent.withAlphaComponent(0.2) : (hovering && isEnabled && DesignSettings.shared.showsHoverFills ? Palette.hoverFill : .clear)
            layer?.backgroundColor = fill.cgColor
            alphaValue = isEnabled ? 1 : 0.4
        }
    }

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        let width = title.isEmpty ? FindPillMetrics.buttonSize : max(FindPillMetrics.buttonSize, size.width + 12)
        return NSSize(width: width, height: FindPillMetrics.buttonSize)
    }
}
