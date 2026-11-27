import AppKit
import QuartzCore

/// One control of the Chief first-run panel, in one of two styles:
///
/// - ``Style/row``: cmux-next's `HomeFirstRunRow`. A 28 pt raised rect
///   (radius 8, continuous, 1 pt hairline; never a capsule) with a leading
///   13 pt glyph or a workspace's 6 pt status dot, a 13 pt label, and
///   trailing 12 pt text: the action's shortcut (tertiary) or the status word
///   (coloured by urgency). Status rows get a clear fill and no border from
///   their ``Colors``, so they read as status rather than as buttons.
/// - ``Style/chip``: a suggestion above the message box in the incoming
///   bubble's fill and text colour, borderless and fully rounded like a
///   one-line Messages bubble (Messages' suggested replies).
///
/// The hover fill follows the pointer, a darker fill shows while pressed.
/// Clicks, VoiceOver's press, and Return or keypad Enter while it has
/// keyboard focus run `onClick` (Space and other printable keys go to the
/// message box, as in cmux-next); arrow keys go to `onNavigate`.
final class ChiefFirstRunRow: NSView {
    enum Style { case row, chip }

    /// What sits in a row's leading slot.
    enum Leading: Equatable {
        case glyph(String)
        case status(ChiefAgentGlance.Status)
    }

    static let height: CGFloat = 28
    static let chipHeight: CGFloat = 30
    static let cornerRadius: CGFloat = 8
    /// A status row's dot (an idle one is a 1 pt ring).
    static let dotSize: CGFloat = 6
    /// Every first-run glyph: one size and weight.
    static let glyphConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)

    let style: Style
    let label: NSTextField
    let trailingLabel = NSTextField(labelWithString: "")
    let glyph = NSImageView()
    var onClick: () -> Void = {}
    /// An arrow key while focused; returns whether it moved focus.
    var onNavigate: (ChiefFirstRunRow, UInt16) -> Bool = { _, _ in false }
    /// The row's width (the panel's column).
    var width: CGFloat = 300 { didSet { if width != oldValue { invalidateIntrinsicContentSize() } } }
    var title: String { label.stringValue }

    /// Trailing text: a shortcut or a status word; nil draws none.
    var trailing: String? {
        didSet {
            guard trailing != oldValue else { return }
            trailingLabel.stringValue = trailing ?? ""
            trailingLabel.isHidden = trailing == nil
            needsLayout = true
        }
    }

    private(set) var leading: Leading
    private let backing = CALayer()
    private let dot = CALayer()
    private var spinner: NSProgressIndicator?

    private var colors: Colors?
    private var isHovered = false { didSet { if isHovered != oldValue { paint() } } }
    private var isPressed = false { didSet { if isPressed != oldValue { paint(quick: true) } } }

    struct Colors {
        var text: NSColor
        var glyph: NSColor
        var trailing: NSColor
        var fill: NSColor
        var hover: NSColor
        var pressed: NSColor
        var border: NSColor?
    }

    init(title: String, leading: Leading, style: Style = .row) {
        label = NSTextField(labelWithString: title)
        self.leading = leading
        self.style = style
        super.init(frame: .zero)
        wantsLayer = true
        backing.cornerCurve = .continuous
        backing.cornerRadius = style == .chip ? Self.chipHeight / 2 : Self.cornerRadius
        backing.borderWidth = style == .row ? 1 : 0
        layer?.addSublayer(backing)
        dot.cornerRadius = Self.dotSize / 2
        layer?.addSublayer(dot)
        glyph.imageScaling = .scaleProportionallyDown
        label.font = .systemFont(ofSize: 13)
        // A chip is sized to its label, so it never cuts its text short.
        label.lineBreakMode = style == .chip ? .byClipping : .byTruncatingTail
        trailingLabel.font = .systemFont(ofSize: 12)
        trailingLabel.lineBreakMode = .byClipping
        trailingLabel.isHidden = true
        for view in [glyph, label, trailingLabel] {
            view.setAccessibilityElement(false)
            addSubview(view)
        }
        setLeading(leading)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: style == .chip ? chipWidth : width, height: style == .chip ? Self.chipHeight : Self.height)
    }

    /// A chip's natural width: glyph, gap, label (with the text field's own
    /// cell padding, which the bare string size leaves out), padding.
    var chipWidth: CGFloat {
        let font = label.font ?? .systemFont(ofSize: 13)
        let text = (label.stringValue as NSString).size(withAttributes: [.font: font]).width
        // The field draws its text 2 pt in from each edge; 2 pt more keeps
        // the last glyph clear of the truncation test at fractional widths.
        return ceil(12 + 15 + 6 + max(text + 6, label.intrinsicContentSize.width) + 14)
    }

    func setLeading(_ leading: Leading) {
        self.leading = leading
        switch leading {
        case .glyph(let symbol):
            glyph.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(Self.glyphConfiguration)
            glyph.isHidden = false
            dot.isHidden = true
            spinner?.stopAnimation(nil)
            spinner?.isHidden = true
        case .status(let status):
            glyph.isHidden = true
            if status == .working {
                dot.isHidden = true
                let spinner = self.spinner ?? makeSpinner()
                spinner.isHidden = false
                if window != nil { spinner.startAnimation(nil) }
            } else {
                dot.isHidden = false
                spinner?.stopAnimation(nil)
                spinner?.isHidden = true
            }
        }
        paint()
        needsLayout = true
    }

    private func makeSpinner() -> NSProgressIndicator {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .mini
        spinner.isDisplayedWhenStopped = false
        spinner.setAccessibilityElement(false)
        addSubview(spinner)
        self.spinner = spinner
        return spinner
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let spinner, !spinner.isHidden else { return }
        if window != nil { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    // MARK: Colours

    func applyColors(_ colors: Colors) {
        self.colors = colors
        paint()
    }

    /// The dot's colour for a status: attention, done, or quiet.
    var statusColor: NSColor? {
        guard case .status(let status) = leading else { return nil }
        return switch status {
        case .needsYou: .systemOrange
        case .done: .systemGreen
        case .working, .idle: colors?.trailing
        }
    }

    private func paint(quick: Bool = false) {
        guard let colors else { return }
        label.textColor = colors.text
        glyph.contentTintColor = colors.glyph
        trailingLabel.textColor = statusColor.flatMap { color in
            if case .status(let status) = leading, status == .needsYou || status == .done { return color }
            return nil
        } ?? colors.trailing
        effectiveAppearance.performAsCurrentDrawingAppearance {
            CATransaction.begin()
            CATransaction.setAnimationDuration(quick ? 0.05 : 0.12)
            backing.backgroundColor = (isPressed ? colors.pressed : isHovered ? colors.hover : colors.fill).cgColor
            // No border colour is no border: a nil CALayer border draws opaque black (the light
            // theme's heavy outlines on the status rows), so the width follows the colour.
            backing.borderColor = (colors.border ?? .clear).cgColor
            backing.borderWidth = style == .row && colors.border != nil ? 1 : 0
            if case .status(let status) = leading {
                let color = statusColor ?? colors.trailing
                dot.backgroundColor = status == .idle ? nil : color.cgColor
                dot.borderColor = color.cgColor
                dot.borderWidth = status == .idle ? 1 : 0
            }
            CATransaction.commit()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let rtl = userInterfaceLayoutDirection == .rightToLeft
        let w = bounds.width, h = bounds.height
        func place(_ r: CGRect) -> CGRect { rtl ? CGRect(x: w - r.maxX, y: r.minY, width: r.width, height: r.height) : r }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        backing.frame = bounds
        let inset: CGFloat = 12
        let side: CGFloat = 15
        let lead = CGRect(x: inset, y: (h - side) / 2, width: side, height: side)
        glyph.frame = place(lead)
        spinner?.frame = place(lead.insetBy(dx: 0.5, dy: 0.5))
        dot.frame = place(CGRect(x: lead.midX - Self.dotSize / 2, y: lead.midY - Self.dotSize / 2,
                                 width: Self.dotSize, height: Self.dotSize))
        let trailingWidth = trailingLabel.isHidden ? 0 : ceil(trailingLabel.attributedStringValue.size().width) + 2
        let trailingHeight = ceil(trailingLabel.intrinsicContentSize.height)
        trailingLabel.alignment = rtl ? .left : .right
        trailingLabel.frame = place(CGRect(x: w - inset - trailingWidth, y: (h - trailingHeight) / 2,
                                           width: trailingWidth, height: trailingHeight))
        let textX = lead.maxX + (style == .chip ? 6 : 10)
        let textEnd = trailingLabel.isHidden ? w - (style == .chip ? 14 : inset) : w - inset - trailingWidth - 8
        let textHeight = ceil(label.intrinsicContentSize.height)
        label.alignment = rtl ? .right : .left
        label.frame = place(CGRect(x: textX, y: (h - textHeight) / 2, width: max(0, textEnd - textX), height: textHeight))
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) {
        isHovered = false
        isPressed = false
    }

    override func mouseDown(with event: NSEvent) { isPressed = true }

    override func mouseDragged(with event: NSEvent) {
        isPressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        if inside { onClick() }
    }

    // MARK: Keyboard

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { !isHiddenOrHasHiddenAncestor }
    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        let radius = style == .chip ? bounds.height / 2 : Self.cornerRadius
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }

    override func keyDown(with event: NSEvent) {
        guard !isHiddenOrHasHiddenAncestor else { return super.keyDown(with: event) }
        switch event.keyCode {
        case 36, 76: // Return, keypad Enter
            if !event.isARepeat { onClick() }
        case 123, 124, 125, 126: // Left, Right, Down, Up
            if !onNavigate(self, event.keyCode) { super.keyDown(with: event) }
        default:
            super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        onClick()
        return true
    }
}
