extension SidebarModel {
    /// Whether the sidebar document's row marks (archived, pinned inside a group) changed since the rows last showed them,
    /// noting `marks` as shown. A mark that moves no row (a member pinned where it already sits) still has to reach the
    /// rows (`sidebar.groupPinMark`), so a show that would otherwise skip as unchanged draws again.
    public func rowMarksMoved(_ marks: SidebarDocProjection.RowMarks?) -> Bool {
        defer { shownRowMarks = marks }
        return marks != shownRowMarks
    }
}
