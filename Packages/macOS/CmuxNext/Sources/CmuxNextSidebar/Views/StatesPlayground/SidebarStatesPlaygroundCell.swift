import CoreGraphics

/// DEV and NIGHTLY (Debug menu > Sidebar States Playground): one state at one column and appearance: the real row's
/// pixels with what was measured on it. Geometry is in the cell's points, top-left origin; `image` is `scale` pixels
/// per point.
struct SidebarStatesPlaygroundCell {
    var state: SidebarStatesPlaygroundState
    /// The row's pixels, the sidebar's whole width and the row's height plus a little air; nil when no row drew it.
    var image: CGImage?
    /// Backing pixels per point of `image`.
    var scale: CGFloat
    /// The cell's size in points.
    var size: CGSize
    /// The row's own frame in the cell.
    var rowFrame: CGRect
    /// The x where the rows' text starts with no icon (the leading inset), measured on an idle row's title.
    var leadingGuideX: CGFloat?
    /// The x every trailing mark centers on, measured on the open group header's chevron.
    var columnGuideX: CGFloat?
    /// The trailing marks the row laid out, leading to trailing.
    var marks: [SidebarStatesPlaygroundMark]
    /// The leading bars beside the row (its color rail, its group's rail), as laid out.
    var bars: [SidebarStatesPlaygroundBar] = []
    /// The hover card drawn beside the row (``SidebarStatesPlaygroundState/pinnedHoverCard`` only), as measured.
    var card: SidebarStatesPlaygroundCard?
    /// The row view's class name (`WorkspaceRowView`, `SidebarItemRowView`, ...); nil when no row drew the state.
    var rowView: String?
}
