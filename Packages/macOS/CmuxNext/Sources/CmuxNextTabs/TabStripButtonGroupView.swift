import AppKit
import CmuxNextDesign
import QuartzCore

/// The trailing button group: compact square gray buttons, one layer pair
/// (fill + glyph) per button. Mouse handling lives in the strip, like the
/// "+" button; this view only draws and answers hit tests by index.
final class TabStripButtonGroupView: NSView {
    private struct Slot {
        var button: TabStripButton
        let fill = CALayer()
        let glyph = CALayer()
        let accessibility = TabButtonAccessibilityElement()
    }

    private var slots: [Slot] = []
    var metrics: TabStripMetrics = .standard { didSet { if oldValue != metrics { needsLayout = true } } }
    var hoveredIndex: Int? { didSet { if oldValue != hoveredIndex { updateColors(animated: true) } } }
    var pressedIndex: Int? { didSet { if oldValue != pressedIndex { updateColors(animated: false) } } }
    var onPress: ((String) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var buttons: [TabStripButton] { slots.map(\.button) }

    /// Width the group needs for `count` buttons, including its leading gap.
    static func width(for count: Int, metrics: TabStripMetrics) -> CGFloat {
        guard count > 0 else { return 0 }
        return metrics.trailingGroupGap + CGFloat(count) * metrics.trailingButtonSize
            + CGFloat(count - 1) * metrics.trailingButtonSpacing
    }

    func setButtons(_ buttons: [TabStripButton]) {
        guard buttons != self.buttons else { return }
        for slot in slots {
            slot.fill.removeFromSuperlayer()
            slot.glyph.removeFromSuperlayer()
        }
        slots = buttons.map { button in
            let slot = Slot(button: button)
            for layer in [slot.fill, slot.glyph] {
                layer.actions = ["bounds": NSNull(), "position": NSNull(), "contents": NSNull()]
                self.layer?.addSublayer(layer)
            }
            slot.fill.cornerRadius = metrics.cornerRadius
            slot.fill.cornerCurve = .continuous
            slot.glyph.contentsGravity = .center
            slot.accessibility.setAccessibilityParent(self)
            slot.accessibility.setAccessibilityLabel(button.accessibilityLabel)
            slot.accessibility.setAccessibilityHelp(button.toolTip)
            let id = button.id
            slot.accessibility.onPress = { [weak self] in self?.onPress?(id) }
            return slot
        }
        if let hoveredIndex, hoveredIndex >= slots.count { self.hoveredIndex = nil }
        if let pressedIndex, pressedIndex >= slots.count { self.pressedIndex = nil }
        needsLayout = true
        updateColors(animated: false)
    }

    /// Button frames in this view's coordinates.
    func buttonFrames() -> [CGRect] {
        let side = metrics.trailingButtonSize
        let y = ((bounds.height - side) / 2).rounded()
        return slots.indices.map { index in
            let x = metrics.trailingGroupGap + CGFloat(index) * (side + metrics.trailingButtonSpacing)
            return CGRect(x: x, y: y, width: side, height: side)
        }
    }

    /// Index of the button under `point` (this view's coordinates).
    func index(at point: CGPoint) -> Int? {
        guard !isHidden else { return nil }
        return buttonFrames().firstIndex { $0.contains(point) }
    }

    func id(at index: Int) -> String? { slots.indices.contains(index) ? slots[index].button.id : nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (slot, frame) in zip(slots, buttonFrames()) {
            slot.fill.frame = frame
            slot.fill.cornerRadius = metrics.cornerRadius
            slot.glyph.frame = frame
            slot.accessibility.setAccessibilityFrameInParentSpace(frame)
        }
        CATransaction.commit()
        updateColors(animated: false)
    }

    override func updateLayer() { updateColors(animated: false) }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors(animated: false)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateColors(animated: false)
    }

    override func accessibilityChildren() -> [Any]? { slots.map(\.accessibility) }

    private func updateColors(animated: Bool) {
        let scale = window?.backingScaleFactor ?? 2
        Motion.transaction(animated ? .hover : nil) { applyColors(scale: scale) }
    }

    private func applyColors(scale: CGFloat) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            for (index, slot) in slots.enumerated() {
                let hovered = hoveredIndex == index, pressed = pressedIndex == index
                slot.fill.backgroundColor = pressed ? Palette.selectionFill.cgColor : (hovered ? Palette.hoverFill.cgColor : nil)
                let tint = hovered || pressed ? Palette.textPrimary : Palette.textSecondary
                slot.glyph.contents = TabButtonIconCache.shared.image(
                    for: slot.button.icon, tint: tint, pointSize: metrics.trailingIconPointSize,
                    size: metrics.trailingIconSize, scale: scale
                )
                slot.glyph.contentsScale = scale
            }
        }
    }
}

/// VoiceOver and automation element for one trailing button.
nonisolated final class TabButtonAccessibilityElement: NSAccessibilityElement, @unchecked Sendable {
    nonisolated(unsafe) var onPress: (@MainActor () -> Void)?

    override init() {
        super.init()
        setAccessibilityRole(.button)
    }

    override func accessibilityPerformPress() -> Bool {
        guard let onPress else { return false }
        MainActor.assumeIsolated { onPress() }
        return true
    }
}
