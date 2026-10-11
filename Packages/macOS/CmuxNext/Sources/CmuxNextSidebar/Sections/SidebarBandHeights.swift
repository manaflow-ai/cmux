public import CmuxNextDesign
public import CoreGraphics

/// How tall the pinned bands are (settings `sidebar.topBandMaxShare`,
/// `sidebar.bottomBandMaxShare`, `sidebar.pinnedBandsScroll`). Pure.
public nonisolated enum SidebarBandHeights {
    /// Heights of the bands above and below the list in `available`
    /// points. With scrolling on, each band stops at its share and scrolls
    /// inside; with it off, each takes its full content. Either way the two
    /// together leave the list `minimumList` (they shrink in proportion and
    /// scroll inside), but each band keeps at least `bandFloor` of its
    /// content (one row: Home and Settings never vanish), even when that
    /// leaves the list less. Sections' `maxRows` caps apply in both modes.
    public static func resolve(above: SidebarRegionLayout, below: SidebarRegionLayout, available: CGFloat,
                               preferences p: SidebarSectionsPreferences, minimumList: CGFloat,
                               bandFloor: CGFloat = 0) -> (above: CGFloat, below: CGFloat) {
        var a = above.cappedHeight, b = below.cappedHeight
        if p.pinnedBandsScroll {
            a = above.pinnedHeight(available: available, share: CGFloat(p.topBandMaxShare))
            b = below.pinnedHeight(available: available, share: CGFloat(p.bottomBandMaxShare))
        }
        let room = max(0, available - minimumList)
        if a + b > room, a + b > 0 {
            let scale = room / (a + b)
            a = floor(a * scale)
            b = floor(b * scale)
        }
        return (max(a, min(above.cappedHeight, bandFloor)), max(b, min(below.cappedHeight, bandFloor)))
    }
}
