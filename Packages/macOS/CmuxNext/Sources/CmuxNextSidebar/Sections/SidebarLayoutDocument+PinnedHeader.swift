extension SidebarLayoutDocument {
    /// The section pinned at the sidebar's top while the workspace list scrolls (Home and the App Store
    /// by default; u2977: "home and app store section ... properly sticky").
    ///
    /// It is the document's first section when that is a top section of items placed before the
    /// workspace list and it holds no group (`grouped`: the ids of the sections that hold one). A group
    /// lists as header and member rows, so a section with one draws in the list and scrolls.
    ///
    /// This is the one rule for the header: ``SidebarDocProjection/arrange(_:drag:)`` lists no section
    /// for it, so the list draws no block for it, the band above the list draws it, and
    /// ``SidebarModel/itemOrder`` counts its items as top items.
    /// - Parameter grouped: The raw ids of the sections that hold a group.
    /// - Returns: The header's id, or nil when the document has none.
    public func pinnedHeaderSectionID(grouped: Set<String>) -> LayoutSectionID? {
        guard let first = sections.first, first.region == .top, first.content != .workspaces,
              !grouped.contains(first.id.rawValue) else { return nil }
        return first.id
    }
}
