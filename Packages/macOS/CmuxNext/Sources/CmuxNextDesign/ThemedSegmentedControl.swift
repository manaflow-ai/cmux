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

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    private func applyTheme() {
        let chip = performWithTheme {
            let tokens = ThemeContext.active ?? ThemeScope.app.tokens
            return tokens.chip(tokens.selectionFill.composited(over: tokens.windowBackground.withAlpha(1)))
        }
        selectedLabelInk = chip.ink.nsColor
        selectedSegmentBezelColor = chip.fill.nsColor
        needsDisplay = true
    }
}

/// Draws the selected segment's label in the control's `selectedLabelInk`; every other segment and
/// all of the bezel are AppKit's.
final class ThemedSegmentedCell: NSSegmentedCell {
    override func drawSegment(_ segment: Int, inFrame frame: NSRect, with controlView: NSView) {
        guard isSelected(forSegment: segment), image(forSegment: segment) == nil,
              let label = label(forSegment: segment), !label.isEmpty,
              let ink = (controlView as? ThemedSegmentedControl)?.selectedLabelInk
        else { return super.drawSegment(segment, inFrame: frame, with: controlView) }
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        let text = NSAttributedString(string: label, attributes: [
            .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize(for: controlSize)),
            .foregroundColor: ink,
            .paragraphStyle: style,
        ])
        let height = ceil(text.size().height)
        text.draw(in: NSRect(x: frame.minX, y: frame.midY - height / 2, width: frame.width, height: height))
    }
}
