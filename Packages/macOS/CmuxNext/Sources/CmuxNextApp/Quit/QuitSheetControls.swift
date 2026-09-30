import AppKit
import CmuxNextDesign

/// A quit sheet button in theme colors (no system accent, so no blue):
/// the default choice has a gray fill, the destructive one red text, the
/// rest plain text; hover and press darken the fill.
final class QuitSheetButton: NSButton {
    enum Style { case primary, destructive, plain }

    private let style: Style
    private var hovering = false
    private var tracking: NSTrackingArea?

    init(title: String, style: Style, target: AnyObject?, action: Selector) {
        self.style = style
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        isBordered = false
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        setButtonType(.momentaryChange)
        updateTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override var intrinsicContentSize: NSSize {
        let text = attributedTitle.size()
        return NSSize(width: ceil(text.width) + 24, height: 28)
    }

    override func updateLayer() {
        performWithTheme {
            let fill: NSColor? = switch (style, isHighlighted, hovering) {
            case (_, true, _): Palette.pressedFill
            case (.primary, false, _): Palette.selectionFill
            case (_, false, true): Palette.hoverFill
            case (_, false, false): nil
            }
            layer?.backgroundColor = fill?.cgColor ?? .clear
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateTitle()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTitle()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        needsDisplay = true
    }

    private func updateTitle() {
        let color = performWithTheme {
            switch style {
            case .primary: Palette.textPrimary
            case .destructive: Palette.danger
            case .plain: Palette.textSecondary
            }
        }
        let weight: NSFont.Weight = style == .primary ? .semibold : .regular
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: weight),
            .foregroundColor: color,
        ])
        invalidateIntrinsicContentSize()
    }
}

/// "Don't ask again": a checkbox drawn with theme-tinted SF Symbols (the
/// system checkbox fills with the accent color).
final class QuitSheetCheckbox: NSButton {
    init(title: String) {
        super.init(frame: .zero)
        setButtonType(.toggle)
        isBordered = false
        focusRingType = .none
        imagePosition = .imageLeading
        imageHugsTitle = true
        image = NSImage(systemSymbolName: "square", accessibilityDescription: nil)
        alternateImage = NSImage(systemSymbolName: "checkmark.square.fill", accessibilityDescription: nil)
        self.title = title
        applyColors()
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColors()
    }

    private func applyColors() {
        let text = title.trimmingCharacters(in: .whitespaces)
        performWithTheme {
            contentTintColor = Palette.textSecondary
            attributedTitle = NSAttributedString(string: " " + text, attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: Palette.textSecondary,
            ])
        }
    }

    var isChecked: Bool {
        get { state == .on }
        set { state = newValue ? .on : .off }
    }
}

/// Borderless sheet panel that can take key (Return, Escape) when shown.
final class QuitSheetPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
