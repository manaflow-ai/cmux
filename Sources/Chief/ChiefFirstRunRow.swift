import AppKit

/// One first-run row: a glyph and a label on a raised small-radius rect with
/// a hairline (never a capsule), taking the hover fill under the pointer
/// (cmux-next `HomeFirstRunRow`). Clicks, VoiceOver's press, and Return
/// while it has keyboard focus run `onClick`; Up and Down move between rows.
final class ChiefFirstRunRow: NSView {
    static let height: CGFloat = 28
    static let cornerRadius: CGFloat = 8

    let surface = NSView()
    let glyph = NSImageView()
    let label: NSTextField
    var onClick: () -> Void = {}
    /// The row's width (the panel's column).
    var width: CGFloat = 300 { didSet { if width != oldValue { invalidateIntrinsicContentSize() } } }

    private var fill = NSColor.clear
    private var hoverFill = NSColor.clear
    private var isHovered = false { didSet { if isHovered != oldValue { paint() } } }

    init(title: String, symbol: String, help: String?) {
        label = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        surface.wantsLayer = true
        surface.layer?.cornerRadius = Self.cornerRadius
        surface.layer?.cornerCurve = .continuous
        surface.layer?.borderWidth = 1
        addSubview(surface)
        glyph.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular))
        glyph.imageScaling = .scaleProportionallyDown
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        addSubview(glyph)
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        setAccessibilityHelp(help)
        toolTip = nil
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: width, height: Self.height) }

    func applyColors(text: NSColor, glyphTint: NSColor, fill: NSColor, hover: NSColor, border: NSColor) {
        label.textColor = text
        glyph.contentTintColor = glyphTint
        self.fill = fill
        hoverFill = hover
        surface.layer?.borderColor = border.cgColor
        paint()
    }

    private func paint() {
        surface.layer?.backgroundColor = (isHovered ? hoverFill : fill).cgColor
    }

    override func layout() {
        super.layout()
        surface.frame = bounds
        let inset: CGFloat = 12
        let side: CGFloat = 16
        glyph.frame = CGRect(x: inset, y: (bounds.height - side) / 2, width: side, height: side)
        let textX = glyph.frame.maxX + 10
        let textHeight = ceil(label.intrinsicContentSize.height)
        label.frame = CGRect(x: textX, y: (bounds.height - textHeight) / 2, width: max(0, bounds.width - inset - textX),
                             height: textHeight)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick() }
    }

    // MARK: Keyboard

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius).fill()
    }

    override func keyDown(with event: NSEvent) {
        guard !isHiddenOrHasHiddenAncestor else { return super.keyDown(with: event) }
        switch event.keyCode {
        case 36, 76: if !event.isARepeat { onClick() } // Return, keypad Enter
        case 125: focusSibling(by: 1) // Down
        case 126: focusSibling(by: -1) // Up
        default: super.keyDown(with: event)
        }
    }

    private func focusSibling(by step: Int) {
        let rows = superview?.subviews.compactMap { $0 as? ChiefFirstRunRow }.filter { !$0.isHiddenOrHasHiddenAncestor } ?? []
        guard let index = rows.firstIndex(where: { $0 === self }), rows.indices.contains(index + step) else { return }
        window?.makeFirstResponder(rows[index + step])
    }

    override func accessibilityPerformPress() -> Bool {
        onClick()
        return true
    }
}
