import AppKit
import CmuxNextDesignTokens

/// The key that presses a dialog button, on a small rounded plate at the button's trailing end ("Not Now esc",
/// "Turn On ↩"; Lawrence 2026-11-09): the Linear-style hint (``CmuxDialogKeycapStyle/linearKbd``, Lawrence
/// 2026-11-16), centred on the button's height one inset from its end, its corners following the button's: its radius
/// is the button's less that inset (concentric). The Keycap Playground draws the other styles to compare. It takes no clicks: the button
/// under it does.
@MainActor
final class CmuxDialogKeycapView: NSView {
    let label: ChromeLabel
    let style: CmuxDialogKeycapStyle
    /// The plate's corner when its owner sets it (a tooltip's, concentric with the tooltip); nil: the style's, concentric
    /// with the dialog button.
    let cornerOverride: CGFloat?

    init(_ glyph: String, style: CmuxDialogKeycapStyle = .linearKbd, cornerRadius: CGFloat? = nil) { // concentric-allow: the owner passes its own nested corner (a tooltip's radius less the keycap inset)
        label = ChromeLabel(labelWithString: glyph)
        self.style = style
        cornerOverride = cornerRadius
        super.init(frame: .zero)
        wantsLayer = true
        label.font = Typography.system(.default, size: style.glyphSize, weight: style.glyphWeight)
        label.alignment = .center
        addSubview(label)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") } // crash-allow: never decoded from a nib

    /// The key's width for `height`: on a plate, the glyph and a little room each side, never narrower than square;
    /// a bare glyph, its own width.
    func width(forHeight height: CGFloat) -> CGFloat {
        guard style.hasPlate else { return ceil(label.naturalSize.width) }
        return max(height, ceil(label.naturalSize.width) + style.platePadding * 2)
    }

    /// The key's height in a button `buttonHeight` tall.
    func height(inButton buttonHeight: CGFloat) -> CGFloat {
        guard style.hasPlate else { return ceil(label.naturalSize.height) }
        return style.plateHeight ?? max(0, buttonHeight - style.trailing * 2)
    }

    /// Colors the plate (the title's ink, faint) and the glyph (the key hint's ink).
    func paint(ink: NSColor, glyph: NSColor) {
        layer?.backgroundColor = style.fillAlpha > 0 ? ink.withAlphaComponent(style.fillAlpha).cgColor : nil
        layer?.borderWidth = style.borderAlpha > 0 ? 1 : 0
        layer?.borderColor = ink.withAlphaComponent(style.borderAlpha).cgColor
        label.textColor = glyph.withAlphaComponent(glyph.alphaComponent * style.glyphAlpha)
    }

    // The button sets the plate's frame in its own layout, after the plate's layout pass: the corner follows the
    // size here too, so it never keeps the corner of an earlier size.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layer?.cornerRadius = plateCornerRadius(fitting: newSize) // concentric-allow: the style's concentric corner, or the owner's nested one
        needsLayout = true
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = plateCornerRadius(fitting: bounds.size) // concentric-allow: the style's concentric corner, or the owner's nested one
        let size = label.naturalSize
        label.frame = NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                             width: size.width, height: size.height)
    }

    /// The plate's corner at `size`: the owner's or the style's, at most half the plate's height; 0 with no plate.
    private func plateCornerRadius(fitting size: NSSize) -> CGFloat {
        guard style.hasPlate else { return 0 }
        guard let cornerOverride else { return style.keycapCornerRadius(fitting: size) }
        return max(0, min(cornerOverride, min(size.width, size.height) / 2))
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
