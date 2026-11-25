import AppKit
import CmuxNextDesign
import CmuxNextHomeModel
import CmuxNextIcons

/// One first-run row: a glyph, a label and the action's shortcut on a raised
/// small-radius rect with a hairline (never a capsule), taking the hover
/// fill under the pointer. A bezel NSButton draws gray when the window is
/// not key and reads as disabled. Clicks, VoiceOver's press, and Return while it has keyboard
/// focus run `onClick`; Space is printable input routed to the Home message box. Tab reaches it
/// and Up and Down move between the rows.
final class HomeFirstRunRow: NSView {
    let surface = NSView()
    let glyph = NSImageView()
    let label: ChromeLabel
    /// The row's cmux icon.
    let icon: IconName
    let shortcutLabel = ChromeLabel(labelWithString: "")
    /// An agent row's state in the shared indicator, before its status word.
    let activity: StatusIndicatorView = { let view = StatusIndicatorView(); view.tracksWindowOcclusion = true; return view }()
    var onClick: () -> Void = {}
    var title: String { label.stringValue }
    /// The row's width (the panel's column).
    var width: CGFloat = 300 { didSet { if width != oldValue { invalidateIntrinsicContentSize() } } }
    /// The action's shortcut, drawn at the trailing edge; nil draws none.
    var shortcut: String? {
        didSet {
            shortcutLabel.stringValue = shortcut ?? ""
            shortcutLabel.isHidden = shortcut == nil
            setAccessibilityHelp(shortcut)
            needsLayout = true
        }
    }

    static let height: CGFloat = 28
    static var cornerRadius: CGFloat { Metrics.controlCornerRadius }
    private var scale: CGFloat = 1
    private var fill = NSColor.clear
    private var hoverFill = NSColor.clear
    private var isHovered = false { didSet { if isHovered != oldValue { paint() } } }

    init(title: String, icon: IconName) {
        label = ChromeLabel(labelWithString: title)
        self.icon = icon
        super.init(frame: .zero)
        surface.wantsLayer = true
        surface.layer?.cornerRadius = Self.cornerRadius
        surface.layer?.cornerCurve = .continuous
        surface.layer?.borderWidth = 1
        addSubview(surface)
        glyph.image = NSImage.icon(icon, size: .iconRowSize(forLabelPointSize: 13))
        glyph.imageScaling = .scaleProportionallyDown
        label.font = .systemFont(ofSize: TypeScale.Base.body)
        label.lineBreakMode = .byTruncatingTail
        shortcutLabel.font = .systemFont(ofSize: TypeScale.Base.detail)
        shortcutLabel.alignment = .right
        shortcutLabel.isHidden = true
        for view in [glyph, label, activity, shortcutLabel] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { nil }

    nonisolated override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize { NSSize(width: width, height: Self.height * scale) }

    /// Applies the live interface scale to the row's type, icon and geometry.
    func applyScale(_ scale: CGFloat) {
        self.scale = scale
        surface.layer?.cornerRadius = Self.cornerRadius * scale
        glyph.image = NSImage.icon(icon, size: .iconRowSize(forLabelPointSize: 13 * scale))
        label.font = .systemFont(ofSize: TypeScale.Base.body * scale)
        shortcutLabel.font = .systemFont(ofSize: TypeScale.Base.detail * scale)
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    /// Colours from the theme (caller runs inside `performWithTheme`).
    func applyColors(text: NSColor, quiet: NSColor, fill: NSColor, hover: NSColor, border: NSColor) { // theme-scoped
        label.textColor = text
        glyph.contentTintColor = text
        shortcutLabel.textColor = quiet
        self.fill = fill
        // The hover token is translucent: composite it over the raised fill.
        hoverFill = fill.blended(withFraction: hover.alphaComponent, of: hover.withAlphaComponent(1)) ?? fill
        surface.layer?.borderColor = border.cgColor
        paint()
    }

    private func paint() {
        surface.layer?.backgroundColor = (isHovered ? hoverFill : fill).cgColor
    }

    override func layout() {
        super.layout()
        surface.frame = bounds
        let inset: CGFloat = 12 * scale
        let side = CGFloat.iconRowSize(forLabelPointSize: 13 * scale)
        glyph.frame = CGRect(x: inset, y: (bounds.height - side) / 2, width: side, height: side)
        let shortcutWidth = shortcutLabel.isHidden ? 0 : ceil(shortcutLabel.attributedStringValue.size().width) + 4
        let shortcutHeight = ceil(shortcutLabel.intrinsicContentSize.height)
        shortcutLabel.frame = CGRect(x: bounds.width - inset - shortcutWidth, y: (bounds.height - shortcutHeight) / 2,
                                     width: shortcutWidth, height: shortcutHeight)
        let indicator: CGFloat = 13 * scale
        activity.frame = CGRect(x: shortcutLabel.frame.minX - indicator - 4 * scale, y: (bounds.height - indicator) / 2,
                                width: indicator, height: indicator)
        let trailing = activity.showsGlyph ? activity.frame.minX : shortcutLabel.frame.minX
        let textX = glyph.frame.maxX + 10 * scale
        let textHeight = ceil(label.intrinsicContentSize.height)
        label.frame = CGRect(x: textX, y: (bounds.height - textHeight) / 2,
                             width: max(0, trailing - 8 * scale - textX), height: textHeight)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick() }
    }

    // MARK: Keyboard

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        let radius = Self.cornerRadius * scale
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }

    override func keyDown(with event: NSEvent) {
        guard !isHiddenOrHasHiddenAncestor else { return super.keyDown(with: event) }
        // Return only: Home sends printable keys, Space included, to the message box first.
        switch event.keyCode {
        case 36, 76: if !event.isARepeat { onClick() } // Return, keypad Enter
        case 125: focusSibling(by: 1) // Down
        case 126: focusSibling(by: -1) // Up
        default: super.keyDown(with: event)
        }
    }

    /// Moves keyboard focus to the previous or next first-run row in the same column.
    private func focusSibling(by step: Int) {
        let rows = superview?.subviews.compactMap { $0 as? HomeFirstRunRow }.filter { !$0.isHiddenOrHasHiddenAncestor } ?? []
        guard let index = rows.firstIndex(where: { $0 === self }), rows.indices.contains(index + step) else { return }
        window?.makeFirstResponder(rows[index + step])
    }

    override func accessibilityPerformPress() -> Bool {
        onClick()
        return true
    }

    func performClick(_ sender: Any?) { onClick() }
}
