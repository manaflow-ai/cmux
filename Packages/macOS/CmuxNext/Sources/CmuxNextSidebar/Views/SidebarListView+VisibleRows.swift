import AppKit
import CmuxVisibleRows

/// The sidebar's rows under the visible-rows contract (`VisibleRowsContract`): a configure, each row frame an apply,
/// a realize or a width change computes, and the rows a full layout or a splice reads count on `listWork`.
extension SidebarListView: VisibleRowsList {
    /// Row views in the list, realized and parked (`recycle` keeps a parked view here, hidden).
    var rowViewsAlive: Int { subviews.reduce(0) { $0 + ($1 is SidebarRowView ? 1 : 0) } }
}
