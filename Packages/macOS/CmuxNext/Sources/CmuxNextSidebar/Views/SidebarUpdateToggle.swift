import AppKit
import CmuxNextDesign
import CmuxNextIcons
import QuartzCore

/// The update card's Automatic Updates control, drawn in theme colors (a
/// system checkbox or switch would draw the system accent). It shows the
/// setting and a click asks to change it; the control follows when the
/// setting changes. By default a compact switch at the card's text edge with
/// the label after it (``SidebarUpdateToggleLook``, Leo 2026-10-20: the filled
/// box read as an unstyled native checkbox; 2026-10-22: "he preferred the
/// checkbox on the left"); Debug Settings brings the checkbox back. The switch's centre sits on the
/// label's cap-height midline, and the knob slides and the track fills on
/// the sidebar's motion gate (Leo 2026-10-22: "a toggle is nicer than a
/// checkbox, just make it look better").
final class SidebarUpdateToggle: NSView {
    var onToggle: ((Bool) -> Void)?
    private(set) var isOn = false
    /// The checkbox's box, or the switch's track (the first sublayer either way: it carries the focus ring).
    private let box = CALayer()
    /// The switch's knob (hidden for the checkbox).
    private let knob = CALayer()
    private let mark = DecorativeImageView() // the checkbox's AXValue says it
    /// The label (internal for the alignment test).
    let label = ChromeLabel(labelWithString: "")
    /// The look this control draws (tests set it; nil follows `sidebar.updateCard.automaticControl`).
    var fixedLook: SidebarUpdateToggleLook? { didSet { if fixedLook != oldValue { needsLayout = true; needsDisplay = true } } }
    var look: SidebarUpdateToggleLook { fixedLook ?? SidebarTunables.updateCardAutomaticControl.value }

    /// Full Keyboard Access focus: the box's edge in the theme's focus color, not the system's blue ring.
    private var isKeyFocused = false { didSet { if isKeyFocused != oldValue { needsDisplay = true } } }
    private var showsKeyFocus: Bool { KeyWindowRepaint.showsFocus(self, focused: isKeyFocused) }
    private lazy var keyRepaint = KeyWindowRepaint(self)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        focusRingType = .none
        box.cornerCurve = .continuous
        box.borderWidth = 1
        box.actions = ["borderColor": NSNull(), "borderWidth": NSNull()]
        layer?.addSublayer(box)
        // The knob and track change only through `slideSwitch()`'s motion transaction (or with actions
        // disabled in layout and updateLayer), so the motion switches and Reduce Motion snap them.
        knob.actions = ["hidden": NSNull()]
        layer?.addSublayer(knob)
        mark.imageScaling = .scaleProportionallyDown
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        [mark, label].forEach(addSubview)
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }
    nonisolated override var wantsUpdateLayer: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    static var font: NSFont { Typography.caption }
    static var boxSize: CGFloat { Metrics.smallIconSize - Metrics.space1 }
    /// The switch's track: as tall as the checkbox's box, a little under twice as wide.
    static var switchSize: CGSize { CGSize(width: ceil(boxSize * 1.75), height: boxSize) }
    static var height: CGFloat { max(boxSize, ceil(font.boundingRectForFont.height)) }

    /// - Parameter animated: Whether a change of `isOn` may slide (the card passes false while it
    ///   is not already showing); it still slides only when ``canSlide``.
    func configure(title: String, isOn: Bool, animated: Bool = true) {
        label.stringValue = title
        let changed = isOn != self.isOn
        self.isOn = isOn
        // Only a switch already on screen slides: the card's first configure (isOn starts false,
        // the track has no frame yet) or a hidden card puts the knob in place with no motion.
        if changed, animated, canSlide { slideSwitch() }
        setAccessibilityLabel(title)
        setAccessibilityValue(isOn ? 1 : 0)
        setAccessibilitySubrole(look == .switchControl ? .switch : nil)
        needsLayout = true
        needsDisplay = true
    }

    /// The label as drawn.
    var title: String { label.stringValue }

    /// The switch has a laid-out track (set by `layout()`'s switch case).
    private(set) var hasLaidOutSwitch = false
    /// A state change animates: the switch has been laid out and is visible in a window. Before
    /// its first layout the track has no frame, so a slide would start from the row's corner.
    var canSlide: Bool { look == .switchControl && hasLaidOutSwitch && window != nil && !isHiddenOrHasHiddenAncestor }

    /// The switch follows a new state: the knob slides and the track fills on the sidebar's
    /// selection spring (`Motion.sidebar`); with animation off it lands in one frame. Layout and
    /// `updateLayer` set the same values with actions disabled, which leaves the slide running.
    private func slideSwitch() {
        Motion.sidebar.transaction(spring: .selection) {
            knob.frame = Self.knobFrame(in: box.frame, isOn: isOn)
            performWithTheme {
                let colors = Self.switchColors(isOn: isOn)
                box.backgroundColor = colors.track.cgColor
                if !showsKeyFocus { box.borderColor = colors.edge.cgColor }
                knob.backgroundColor = colors.knob.cgColor
            }
        }
    }

    /// Where the switch's centre goes in a row whose label sits at `labelTop`: the label's
    /// cap-height midline (its first baseline less half the cap height), so the switch and the
    /// label's letters share one centre line rather than two boxes' centres.
    static func switchMidY(labelTop: CGFloat, baseline: CGFloat, font: NSFont) -> CGFloat {
        labelTop + baseline - font.capHeight / 2
    }

    override func layout() {
        super.layout()
        let side = Self.boxSize, b = bounds
        label.font = Self.font
        let th = ceil(label.intrinsicContentSize.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch look {
        case .switchControl:
            // The switch at the card's text edge, the label after it (the checkbox's place).
            let track = Self.switchSize
            let labelTop = (b.height - th) / 2
            let midY = Self.switchMidY(labelTop: labelTop, baseline: label.firstBaselineOffsetFromTop, font: Self.font)
            let trackY = (window?.backingScaleFactor).map { scale in ((midY - track.height / 2) * scale).rounded() / scale }
                ?? (midY - track.height / 2).rounded()
            let trackFrame = CGRect(x: 0, y: trackY, width: track.width, height: track.height)
            box.frame = trackFrame
            hasLaidOutSwitch = !trackFrame.isEmpty
            box.cornerRadius = track.height / 2
            knob.frame = Self.knobFrame(in: trackFrame, isOn: isOn)
            knob.cornerRadius = knob.frame.height / 2
            knob.isHidden = false
            mark.isHidden = true
            let x = trackFrame.maxX + Metrics.space2
            label.frame = NSRect(x: x, y: labelTop, width: max(0, b.width - x), height: th)
        case .checkbox:
            let boxFrame = CGRect(x: 0, y: (b.height - side) / 2, width: side, height: side)
            box.frame = boxFrame
            box.cornerRadius = Metrics.space1
            hasLaidOutSwitch = false
            knob.isHidden = true
            let inset = side * 0.18
            mark.image = NSImage.icon(.stateSelected, size: side - 2 * inset)
            mark.frame = boxFrame.insetBy(dx: inset, dy: inset)
            let x = boxFrame.maxX + Metrics.space2
            label.frame = NSRect(x: x, y: (b.height - th) / 2, width: max(0, b.width - x), height: th)
        }
        CATransaction.commit()
    }

    /// The switch's knob in `track`: a circle inset by 2 pt, at the trailing end when on.
    static func knobFrame(in track: CGRect, isOn: Bool) -> CGRect {
        let inset: CGFloat = 2, side = max(0, track.height - 2 * inset)
        let x = isOn ? track.maxX - inset - side : track.minX + inset
        return CGRect(x: x, y: track.minY + inset, width: side, height: side)
    }

    /// The switch's track and knob colors (theme-scoped: call inside `performWithTheme`): the
    /// theme's accent pair when on, a quiet fill with a hairline and a muted knob when off.
    static func switchColors(isOn: Bool) -> (track: NSColor, knob: NSColor, edge: NSColor) {
        isOn ? (Palette.accentFill, Palette.onAccent, Palette.accentFill)
            : (Palette.hoverFill, Palette.textTertiary, Palette.separator)
    }

    override func updateLayer() {
        // Sublayers have no view delegate: without this every color here would take Core
        // Animation's default implicit fade, outside the motion gate.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        performWithTheme {
            switch look {
            case .switchControl:
                let colors = Self.switchColors(isOn: isOn)
                box.backgroundColor = colors.track.cgColor
                box.borderColor = (showsKeyFocus ? Palette.focusRing : colors.edge).cgColor
                box.borderWidth = showsKeyFocus ? Metrics.lineWidth(1.5) : Metrics.lineWidth(1)
                knob.backgroundColor = colors.knob.cgColor
                // A small lift so the knob reads as a part that slides (the tooltip's elevation).
                knob.shadowColor = Palette.shadow.cgColor
                knob.shadowOpacity = Float(PopupStyle.elevation1.alpha)
                knob.shadowRadius = PopupStyle.elevation1.layerRadius
                knob.shadowOffset = PopupStyle.elevation1.layerOffset(flipped: isFlipped)
                mark.isHidden = true
            case .checkbox:
                box.backgroundColor = (isOn ? Palette.textPrimary : NSColor.clear).cgColor
                box.borderColor = (showsKeyFocus ? Palette.focusRing : isOn ? Palette.textPrimary : Palette.textTertiary).cgColor
                box.borderWidth = showsKeyFocus ? Metrics.lineWidth(1.5) : 1
                mark.contentTintColor = Palette.textOnPrimary
                mark.isHidden = !isOn
            }
            label.textColor = Palette.textSecondary
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        toggle()
    }

    /// A click: asks for the other state; the box changes when the setting does.
    func toggle() { onToggle?(!isOn) }

    override func accessibilityPerformPress() -> Bool {
        toggle()
        return true
    }

    override var acceptsFirstResponder: Bool { NSApp.isFullKeyboardAccessEnabled }
    override var canBecomeKeyView: Bool { acceptsFirstResponder && !isHiddenOrHasHiddenAncestor }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        keyRepaint.track()
    }

    override func becomeFirstResponder() -> Bool {
        isKeyFocused = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        isKeyFocused = false
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard Self.isActivationKey(event) else { return super.keyDown(with: event) }
        toggle()
    }

    /// Space or Return without modifiers.
    static func isActivationKey(_ event: NSEvent) -> Bool {
        event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.function).isEmpty
            && [" ", "\r", "\u{3}"].contains(event.charactersIgnoringModifiers ?? "")
    }
}
