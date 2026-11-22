public import AppKit

/// Where a tab's chip is in a strip, for anchors drawn outside the strip
/// (the agent cursor's hidden-tab indicator). A separate type so the strip
/// itself does not grow.
public struct TabChipAnchor {
    public init() {}
    /// The chip of `id` in `strip`'s coordinates (flipped). A chip scrolled
    /// out of the strip's tab area is pinned to the nearest edge of that
    /// area, keeping its size. Nil when the tab has no laid-out chip (unknown
    /// id, or a member of a collapsed group).
    public static func rect(of id: TabID, in strip: TabStripView) -> CGRect? {
        guard let cell = strip.cells[id], cell.frame.width > 0.5 else { return nil }
        let chip = clamped(cell.frame, into: strip.tabsClip.bounds)
        return strip.tabsClip.convert(chip, to: strip)
    }

    /// `chip` moved horizontally into `area`, never wider than it.
    static func clamped(_ chip: CGRect, into area: CGRect) -> CGRect {
        let width = min(chip.width, area.width)
        let x = min(max(chip.minX, area.minX), area.maxX - width)
        return CGRect(x: x, y: chip.minY, width: width, height: chip.height)
    }
}
