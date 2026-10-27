public import AppKit

/// A segmented control whose selected segment is the theme's selection fill instead of the
/// system's, re-resolved in its scope when it moves into a window and on every theme change. The
/// fill is `Palette.selectionFill` composited over the window background and nudged until its
/// label ink holds 4.5:1 (`ThemeTokens.chip`), and the selected label draws in that ink: with a
/// custom bezel color AppKit draws the selected label in its accent style, which can vanish on
/// the theme's fill. Keys and VoiceOver are the stock control's.
public final class ThemedSegmentedControl: NSSegmentedControl {
    /// The ink the selected segment's label draws in (nil until the control resolves its theme).
    @objc public private(set) var selectedLabelInk: NSColor?

    public override class var cellClass: AnyClass? {
        get { ThemedSegmentedCell.self }
        set {}
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyTheme()
    }

    // visibility-walk-allow: two color stores and one invalidation when they change; cheaper than a deferral
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    private func applyTheme() {
        let chip = performWithTheme {
            let tokens = ThemeContext.active ?? ThemeScope.app.tokens
            return tokens.chip(tokens.selectionFill.composited(over: tokens.windowBackground.withAlpha(1)))
        }
        let ink = chip.ink.nsColor, fill = chip.fill.nsColor
        // A move into a window, or a theme change, that leaves the chip as it was repaints nothing.
        guard ink != selectedLabelInk || fill != selectedSegmentBezelColor else { return }
        selectedLabelInk = ink
        selectedSegmentBezelColor = fill
        needsDisplay = true // invalidate: another chip (the guard above); the selected label draws in its ink.
    }
}

/// Draws the selected segment's label in the control's `selectedLabelInk`; every other segment, all
/// of the bezel, and a disabled control or segment (dimmed as AppKit dims it) are AppKit's.
///
/// A window that isn't key: AppKit's docs don't say whether a custom `selectedSegmentBezelColor`
/// gets an inactive fill there, and the code can't tell, so the label keeps its ink. If dogfood
/// shows an inactive gray fill under it, fall back to super while `controlView.window?.isKeyWindow`
/// is false.
final class ThemedSegmentedCell: NSSegmentedCell {
    override func drawSegment(_ segment: Int, inFrame frame: NSRect, with controlView: NSView) {
        guard isSelected(forSegment: segment), image(forSegment: segment) == nil,
              let control = controlView as? ThemedSegmentedControl, control.isEnabled, isEnabled(forSegment: segment),
              let label = label(forSegment: segment), !label.isEmpty, let ink = control.selectedLabelInk
        else { return super.drawSegment(segment, inFrame: frame, with: controlView) }
        let font = font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize(for: controlSize))
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        let text = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: ink, .paragraphStyle: style])
        // Center the capitals on the segment, as AppKit centers its labels, not the line box
        // (whose descender space would sit the text high).
        let height = ceil(font.ascender - font.descender + font.leading)
        let lineTop = controlView.isFlipped
            ? frame.midY + font.capHeight / 2 - font.ascender
            : frame.midY - font.capHeight / 2 + font.ascender
        let originY = controlView.isFlipped ? lineTop : lineTop - height
        text.draw(with: NSRect(x: frame.minX, y: originY, width: frame.width, height: height),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}
