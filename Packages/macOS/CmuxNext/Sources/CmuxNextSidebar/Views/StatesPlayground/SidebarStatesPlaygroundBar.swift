import CoreGraphics

/// DEV and NIGHTLY (Debug menu > Sidebar States Playground, Lawrence msg 19775): one leading bar beside a row (a
/// colored workspace's left rail, an open group's member rail), as its real view laid it out: its frame and the
/// corner radius its layer gives its top and its bottom ends.
struct SidebarStatesPlaygroundBar: Equatable, Sendable {
    /// What drew the bar: the view's class name (`NSView` for a row's color rail, `GroupLineView` for a group's).
    var view: String
    /// The bar's frame in the cell's points (top-left origin); a group's rail runs past its member row.
    var frame: CGRect
    /// The rounding of the bar's top end, in points (the layer's corner radius when its masked corners include it).
    var topRadius: CGFloat
    /// The rounding of the bar's bottom end, in points.
    var bottomRadius: CGFloat

    /// "▮ 3×16 r1.5/1.5": width × height, then the top and bottom radii, for the cell's caption.
    var sizeText: String {
        "▮ \(SidebarStatesPlaygroundMark.text(frame.size)) r\(SidebarStatesPlaygroundMark.text(CGSize(width: topRadius, height: topRadius)))"
            + "/\(SidebarStatesPlaygroundMark.text(CGSize(width: bottomRadius, height: bottomRadius)))"
    }
}
