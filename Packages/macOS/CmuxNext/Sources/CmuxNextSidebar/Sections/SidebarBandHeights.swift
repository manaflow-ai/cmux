public import CmuxNextDesign
public import CoreGraphics

/// How tall the sticky bands are (settings `sidebar.topBandMaxShare`,
/// `sidebar.bottomBandMaxShare`, `sidebar.stickyBandsScroll`). Pure.
public nonisolated enum SidebarBandHeights {
    /// Heights of the bands above and below the list in `available`
    /// points. With scrolling on, each band stops at its share and scrolls
    /// inside. With it off, the bands take their full content and the list
    /// shrinks, down to `minimumList`; past that both bands shrink in
    /// proportion and scroll as a last resort. Sections' `maxRows` caps
    /// apply in both modes.
    public static func resolve(above: SidebarRegionLayout, below: SidebarRegionLayout, available: CGFloat,
                               preferences p: SidebarSectionsPreferences, minimumList: CGFloat,
                               bandFloor: CGFloat = 0) -> (above: CGFloat, below: CGFloat) {
        if p.stickyBandsScroll {
            return (above.stickyHeight(available: available, share: CGFloat(p.topBandMaxShare)),
                    below.stickyHeight(available: available, share: CGFloat(p.bottomBandMaxShare)))
        }
        let a = above.cappedHeight, b = below.cappedHeight
        let room = max(0, available - minimumList)
        guard a + b > room, a + b > 0 else { return (a, b) }
        let scale = room / (a + b)
        return (floor(a * scale), floor(b * scale))
    }
}
