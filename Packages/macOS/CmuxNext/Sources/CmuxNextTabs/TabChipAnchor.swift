public import AppKit

/// Where a tab's chip is in a strip, for anchors drawn outside the strip
/// (the agent cursor's hidden-tab indicator). A separate type so the strip
/// itself does not grow.
public enum TabChipAnchor {
    /// The chip of `id` in `strip`'s coordinates (flipped). A chip scrolled
    /// out of the strip's tab area is pinned to the nearest edge of that
    /// area, keeping its size. Nil when the tab has no laid-out chip (unknown
    /// id, or a member of a collapsed group).
    public static func rect(of id: TabID, in strip: TabStripView) -> CGRect? {
        nil // red
    }

    /// `chip` moved horizontally into `area`, never wider than it.
    static func clamped(_ chip: CGRect, into area: CGRect) -> CGRect {
        chip // red
    }
}
