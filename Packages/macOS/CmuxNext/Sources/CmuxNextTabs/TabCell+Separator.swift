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

    /// The theme's separator tone, stronger than a pane hairline so a 1 pt line reads between tabs;
    /// clear under `appearance.borders` none. Runs inside the cell's theme scope.
    func applySeparatorColor() {
        separatorLayer.backgroundColor = Borders.color(Palette.separator.withAlphaComponent(metrics.separatorOpacity)).cgColor
    }
}
