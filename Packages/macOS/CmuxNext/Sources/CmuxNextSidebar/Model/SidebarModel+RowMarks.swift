extension SidebarModel {
    /// Whether the sidebar document's row marks (archived, pinned inside a group) changed since the rows last showed them,
    /// noting the current ones. A mark that moves no row (a member pinned where it already sits) still has to reach the
    /// rows (`sidebar.groupPinMark`), so a show that would otherwise skip as unchanged draws again.
    public func rowMarksMoved() -> Bool {
        let marks = SidebarDocStore.current?.shown?.rowMarks
        defer { shownRowMarks = marks }
        return marks != shownRowMarks
    }
}
