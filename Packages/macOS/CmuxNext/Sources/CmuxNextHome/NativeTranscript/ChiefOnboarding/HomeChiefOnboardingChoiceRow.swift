import AppKit
import CmuxNextDesign
import CmuxNextHomeModel

/// One permission mode on Meet Chief's access step: a radio mark, the mode's Settings name and what it means,
/// on a raised small-radius rect. The picked mode takes the accent on its mark and its hairline. A click, VoiceOver's
/// press or Return while it has keyboard focus picks it; Up and Down move between the modes.
final class HomeChiefOnboardingChoiceRow: NSView {
    let mode: ChiefPermissionMode
    let surface = NSView()
    /// The radio mark and its centre dot: views, so their frames are in this row's flipped space.
    let mark = NSView()
    let dot = NSView()
    let title: ChromeLabel
    let detail: ChromeLabel
    var onClick: () -> Void = {}
    /// The mode is the one in effect (or the person's pick while it saves).
    var isOn = false { didSet { if isOn != oldValue { paint(); setAccessibilityValue(isOn) } } }
    /// The person may pick it (false: an administrator sets the mode).
    var isEnabled = true { didSet { if isEnabled != oldValue { setAccessibilityEnabled(isEnabled); paint() } } }
    private var scale: CGFloat = 1
    private var colors: (primary: NSColor, secondary: NSColor, quiet: NSColor, fill: NSColor, hover: NSColor, border: NSColor,
                         accent: NSColor, onAccent: NSColor)?
    private var isHovered = false { didSet { if isHovered != oldValue { paint() } } }

    static let padding: CGFloat = 10
    static let markSide: CGFloat = 14
    static let markGap: CGFloat = 10

    init(mode: ChiefPermissionMode, title: String, detail: String) {
        self.mode = mode
        self.title = ChromeLabel(labelWithString: title)
        self.detail = ChromeLabel(wrappingLabelWithString: detail)
        super.init(frame: .zero)
        surface.wantsLayer = true
        surface.layer?.cornerCurve = .continuous
        surface.layer?.borderWidth = 1
        addSubview(surface)
        for view in [mark, dot] {
            view.wantsLayer = true
            view.setAccessibilityElement(false)
        }
        mark.layer?.borderWidth = 1.5
        mark.addSubview(dot)
        addSubview(mark)
        self.title.isSelectable = false
        self.title.lineBreakMode = .byTruncatingTail
        self.detail.isSelectable = false
        self.detail.maximumNumberOfLines = 0
        for view in [self.title, self.detail] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(title)
        setAccessibilityHelp(detail)
        setAccessibilityValue(false)
        applyScale(1)
    }

    required init?(coder: NSCoder) { nil }

    nonisolated override var isFlipped: Bool { true }

    func applyScale(_ scale: CGFloat) {
        self.scale = scale
        surface.layer?.cornerRadius = Metrics.controlCornerRadius * scale
        title.font = .systemFont(ofSize: TypeScale.Base.body * scale, weight: TypeScale.emphasis)
        detail.font = .systemFont(ofSize: TypeScale.Base.detail * scale)
        needsLayout = true
    }

    func applyColors(primary: NSColor, secondary: NSColor, quiet: NSColor, fill: NSColor, hover: NSColor, border: NSColor,
                     accent: NSColor, onAccent: NSColor) { // theme-scoped
        // The hover token is translucent: composite it over the raised fill.
        let lit = fill.blended(withFraction: hover.alphaComponent, of: hover.withAlphaComponent(1)) ?? fill
        colors = (primary, secondary, quiet, fill, lit, border, accent, onAccent)
        title.textColor = primary
        detail.textColor = secondary
        paint()
    }

    private func paint() {
        guard let colors else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surface.layer?.backgroundColor = (isHovered && isEnabled && !isOn ? colors.hover : colors.fill).cgColor
        surface.layer?.borderColor = (isOn ? colors.accent : colors.border).cgColor
        mark.layer?.borderColor = (isOn ? colors.accent : colors.quiet).cgColor
        mark.layer?.backgroundColor = (isOn ? colors.accent : NSColor.clear).cgColor
        dot.layer?.backgroundColor = colors.onAccent.cgColor
        dot.isHidden = !isOn
        CATransaction.commit()
    }

    private var textX: CGFloat { (Self.padding + Self.markSide + Self.markGap) * scale }

    /// The row's height in a column `width` wide.
    func height(for width: CGFloat) -> CGFloat {
        let inner = max(0, width - textX - Self.padding * scale)
        return 2 * Self.padding * scale + ceil(title.intrinsicContentSize.height) + ceil(detail.size(forWidth: inner).height)
    }

    override func layout() {
        super.layout()
        surface.frame = bounds
        let pad = Self.padding * scale, inner = max(0, bounds.width - textX - pad)
        let titleHeight = ceil(title.intrinsicContentSize.height)
        title.frame = CGRect(x: textX, y: pad, width: inner, height: titleHeight)
        detail.frame = CGRect(x: textX, y: title.frame.maxY, width: inner, height: ceil(detail.size(forWidth: inner).height))
        // The mark sits on the title's line.
        let side = Self.markSide * scale, dotSide = (side * 0.4).rounded()
        mark.frame = CGRect(x: pad, y: pad + (titleHeight - side) / 2, width: side, height: side)
        mark.layer?.cornerRadius = side / 2
        dot.frame = CGRect(x: (side - dotSide) / 2, y: (side - dotSide) / 2, width: dotSide, height: dotSide)
        dot.layer?.cornerRadius = dotSide / 2
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func mouseUp(with event: NSEvent) {
        if isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) { onClick() }
    }

    override var acceptsFirstResponder: Bool { isEnabled }
    override var canBecomeKeyView: Bool { isEnabled }
    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        let radius = Metrics.controlCornerRadius * scale
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }

    override func keyDown(with event: NSEvent) {
        guard isEnabled, !isHiddenOrHasHiddenAncestor else { return super.keyDown(with: event) }
        switch event.keyCode {
        case 36, 76: if !event.isARepeat { onClick() } // Return, keypad Enter
        case 125: focusSibling(by: 1) // Down
        case 126: focusSibling(by: -1) // Up
        default: super.keyDown(with: event)
        }
    }

    private func focusSibling(by step: Int) {
        let rows = superview?.subviews.compactMap { $0 as? HomeChiefOnboardingChoiceRow }.filter { !$0.isHiddenOrHasHiddenAncestor } ?? []
        guard let index = rows.firstIndex(where: { $0 === self }), rows.indices.contains(index + step) else { return }
        _ = FocusRoute(.person, "Up or Down in Meet Chief's mode choices").moveKeyboard(in: window, to: rows[index + step])
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        onClick()
        return true
    }
}
