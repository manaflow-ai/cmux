import AppKit
import CmuxNextDesign
import QuartzCore

/// The short line in the gap after a tab's pill (Leo 2026-10-14: some separator between tabs,
/// minimal but noticeable). The strip decides which lines show (`TabSeparatorVisibility`).
extension TabCell {
    /// Hidden until the strip shows it.
    static func makeSeparatorLayer() -> CALayer {
        let line = CALayer()
        line.opacity = 0
        return line
    }

    /// Shown or hidden at once (Chrome): no fade lag behind hover.
    var showsSeparator: Bool {
        get { separatorLayer.opacity > 0 }
        set { separatorLayer.opacity = newValue ? 1 : 0 }
    }

    /// A 1 pt line on the pixel grid, centered in the gap after the pill.
    func layoutSeparator(slot: CGRect, pill: CGRect) {
        let line = max(1 / scale, pixel(1))
        let height = pixel(min(metrics.separatorHeight, slot.height))
        separatorLayer.frame = CGRect(x: pixel(pill.maxX + (slot.width - pill.maxX - line) / 2), y: pixel((slot.height - height) / 2),
                                      width: line, height: height)
    }

    /// The chrome's divider colour at the tab separators' strength (`Palette.chromeDivider(opacity:)`), so the
    /// strip draws no third line weight; clear under `appearance.borders` none. Runs inside the cell's theme scope.
    func applySeparatorColor() {
        separatorLayer.backgroundColor = Borders.color(Palette.chromeDivider(opacity: metrics.separatorOpacity)).cgColor
    }
}

// `experiments.tabBarStyle` underline (Primer's underline nav, Geist's tabs): plain labels, the selected one at the
// emphasis weight over a 2 pt accent rule that sits on the strip's bottom hairline (`TabStripView.layoutBarStyle`).
extension TabCell {
    /// The rule's thickness.
    static let underlineThickness: CGFloat = 2

    /// `font` at the type scale's emphasis weight (semibold), the same size.
    static func emphasized(_ font: NSFont) -> NSFont {
        Typography.system(.default, size: font.pointSize, weight: TypeScale.emphasis)
    }

    /// The font titles are measured in: the underline look measures every title at the selected weight, so a tab's
    /// fade, truncation and marquee are the same selected or not and bolding moves nothing (the tab's width is the
    /// strip's layout, never its text).
    var titleMeasureFont: NSFont { metrics.barStyle == .underline ? Self.emphasized(titleFont) : titleFont }

    /// The underline look draws the selected title at the emphasis weight; every other title, and every other look,
    /// the strip's title font. Set only on a change.
    func applyTitleWeight() {
        let font = metrics.barStyle == .underline && isSelected ? Self.emphasized(titleFont) : titleFont
        if titleLayer.font != font { titleLayer.font = font }
    }

    /// The selected tab's rule in the underline look: under its content (the content insets of the pill), on the
    /// strip's bottom edge (``underlineDrop`` below the pill). Only the selected tab has the layer, so a switch costs
    /// two cells at any tab count. `onPath`: a sample of a moving width, which hides nothing and removes nothing.
    func layoutUnderline(pill: CGRect, onPath: Bool) {
        guard metrics.barStyle == .underline, isSelected else {
            if !onPath, let underlineLayer {
                underlineLayer.removeFromSuperlayer()
                self.underlineLayer = nil
            }
            return
        }
        let line: CALayer
        if let underlineLayer {
            line = underlineLayer
        } else {
            line = CALayer()
            line.actions = Self.noActions
            themeScope.perform { line.backgroundColor = Palette.accent.cgColor }
            layer.insertSublayer(line, above: backgroundLayer)
            underlineLayer = line
        }
        let inset = min(metrics.contentLeadingInset, pill.width / 4)
        let thickness = Self.underlineThickness
        line.frame = CGRect(x: pixel(pill.minX + inset), y: pixel(pill.maxY + underlineDrop - thickness),
                            width: max(0, pixel(pill.width - 2 * inset)), height: thickness)
    }
}
