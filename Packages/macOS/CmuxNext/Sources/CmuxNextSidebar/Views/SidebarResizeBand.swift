import CoreGraphics

/// Where the sidebar's resize grab area sits around the sidebar's edge facing the content.
///
/// The band is a hit area only: it lies over the sidebar and over the gutter or content beside
/// it, and moves no frame. Most of it goes outside, over the empty gutter beside the curved
/// main pane, so it takes few clicks from the sidebar's rows; a few points stay inside, so the
/// edge is grabbable from either side (u2255).
struct SidebarResizeBand: Equatable {
    /// Points of the band inside the sidebar.
    var inside: CGFloat
    /// Points of the band outside the sidebar, over its neighbor.
    var outside: CGFloat

    var width: CGFloat { inside + outside }

    /// The narrowest band: 10 pt, the gutter beside the curved main pane (6 pt) and 4 pt of the
    /// sidebar. The pane dividers' 7 pt hit width alone left a 3.5 pt target here.
    static let minimumWidth: CGFloat = 10

    /// - Parameter width: The band's total width.
    /// - Parameter gutter: The empty gutter beside the sidebar (`Metrics.mainPaneGutter`, 0 when
    ///   the main pane is flush). The outside half grows into it, up to all but 4 pt of `width`.
    init(width: CGFloat, gutter: CGFloat) {
        let half = width / 2
        outside = min(max(gutter, half), max(half, width - 4))
        inside = width - outside
    }
}
