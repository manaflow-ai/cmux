import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// The omnibar's leading page-info button (the location icon): the
/// tune icon for secure pages, a "Not secure" / "Dangerous" chip with text,
/// or an input icon while the user types. Transparent at rest with a 6 pt
/// hover shape. Opens page info on click, Space or Return.
final class PageInfoChipButton: NSView, PointerHoverReporting {
    var onPress: (() -> Void)?

    var indicator = PageInfoIndicator(symbol: PageInfoIndicator.searchSymbol, isTriggerable: false) {
        didSet { if oldValue != indicator { apply() } }
    }

    private let icon = NSImageView()
    private let text = ChromeLabel(labelWithString: "")
    private let density = DensityBinding()
    /// Where the pointer is now (`OmnibarPointer`); no hover while the chip
    /// opens nothing.
    private var hover: PointerHover?
    private var isHovering: Bool { hover?.isHovering ?? false }
    var isPointerHovering: Bool { isHovering }
    private var isPressed = false { didSet { refreshFill() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        focusRingType = .none
        layer?.cornerRadius = OmnibarStyle.chipCornerRadius
        layer?.cornerCurve = .continuous
        icon.imageScaling = .scaleNone
        text.isHidden = true
        text.lineBreakMode = .byClipping
        addSubview(icon)
        addSubview(text)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        density.update { [weak self] in self?.apply() }
        density.start()
        hover = PointerHover(self) { [weak self] _ in self?.refreshFill(animated: true) }
        hover?.isHoverable = { [weak self] in self?.indicator.isTriggerable ?? false }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var labelText: String? {
        switch indicator.label {
        case .notSecure: PageInfoStrings.notSecure
        case .dangerous: PageInfoStrings.dangerous
        case .file: PageInfoStrings.file
        case .product: PageInfoStrings.product
        case .keyword(let name): name
        case nil: nil
        }
    }

    private func applyTint() {
        performWithTheme {
            let tint = indicator.tone == .danger ? PageInfoStyle.danger : OmnibarStyle.textPrimary
            icon.contentTintColor = tint
            text.textColor = tint
        }
    }

    private func apply() {
        icon.image = NSImage.icon(symbol: indicator.symbol, size: .iconRowSize(forLabelPointSize: OmnibarStyle.iconPointSize))
        applyTint()
        text.font = OmnibarStyle.font
        text.stringValue = labelText ?? ""
        text.isHidden = labelText == nil
        themedToolTip = indicator.isTriggerable ? PageInfoStrings.viewSiteInformation : nil
        setAccessibilityLabel([PageInfoStrings.viewSiteInformation, labelText].compactMap(\.self).joined(separator: ", "))
        setAccessibilityEnabled(indicator.isTriggerable)
        hover?.refresh()
        if !indicator.isTriggerable { isPressed = false }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override var intrinsicContentSize: NSSize {
        let side = OmnibarStyle.chipSize
        guard !text.isHidden else { return NSSize(width: side, height: side) }
        let padding = (side - OmnibarStyle.iconPointSize) / 2
        return NSSize(width: ceil(side + text.intrinsicContentSize.width + padding), height: side)
    }

    override func layout() {
        super.layout()
        let side = bounds.height
        let iconSize = icon.intrinsicContentSize
        icon.frame = NSRect(x: (side - iconSize.width) / 2, y: (side - iconSize.height) / 2, width: iconSize.width, height: iconSize.height)
        let size = text.intrinsicContentSize
        text.frame = NSRect(x: side - 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }

    // MARK: Mouse and keyboard

    override func hitTest(_ point: NSPoint) -> NSView? {
        indicator.isTriggerable ? super.hitTest(point) : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidHide() {
        super.viewDidHide()
        hover?.refresh()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        hover?.refresh()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hover?.refresh()
    }

    override func mouseDown(with event: NSEvent) {
        guard indicator.isTriggerable else { return }
        isPressed = true
    }

    /// Page info opens on release inside the button.
    override func mouseUp(with event: NSEvent) {
        guard isPressed else { return }
        isPressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
    }

    /// Focusable with Full Keyboard Access, like other toolbar buttons.
    override var acceptsFirstResponder: Bool { indicator.isTriggerable && NSApp.isFullKeyboardAccessEnabled }
    override var canBecomeKeyView: Bool { acceptsFirstResponder }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " || event.keyCode == 36 || event.keyCode == 76 {
            onPress?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        guard indicator.isTriggerable else { return false }
        onPress?()
        return true
    }

    // Gray keyboard focus instead of the accent-colored system ring.
    override func becomeFirstResponder() -> Bool {
        showsFocus = true
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        showsFocus = false
        return super.resignFirstResponder()
    }

    private var showsFocus = false { didSet { refreshFill() } }

    /// The hover fill eases in and clears at once; a press shows at once (`ChromeHover.fade`).
    private func refreshFill(animated: Bool = false) {
        layer?.borderWidth = Metrics.lineWidth(showsFocus ? 1.5 : 0)
        guard let layer else { return }
        performWithTheme {
            let fill: NSColor? = isPressed ? PageInfoStyle.pressed : (isHovering ? OmnibarStyle.chipHoverFill : nil)
            ChromeHover.paint(layer, fill, animated: animated && window != nil, pressed: isPressed)
            layer.borderColor = PageInfoStyle.focusRing.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshFill()
        applyTint()
    }
}
