public import AppKit

extension NSFont {
    /// Where an icon `iconHeight` tall puts its first baseline, from its top, so that on a
    /// first-baseline row its center sits on the middle of this font's capitals on the line's
    /// first line (half the cap height above the baseline).
    ///
    /// Lawrence 2026-10-21: "vertical alignment here is still bad". Centering an icon on its label
    /// (`NSStackView.Alignment.centerY`) put it between the lines of wrapped text and a little low
    /// on one line, since a label's frame adds the descender and leading below the capitals. Every
    /// hover card icon (`HoverCardIconView`, `HoverCardIconSlot`, a row's trailing mark) uses this
    /// one rule instead, whatever its line wraps to.
    /// - Parameter iconHeight: The icon's height in points (its constraint, not its bounds).
    /// - Returns: The baseline offset from the icon's top, in points.
    public func iconBaselineOffsetFromTop(iconHeight: CGFloat) -> CGFloat {
        iconHeight / 2 + capHeight / 2
    }
}
