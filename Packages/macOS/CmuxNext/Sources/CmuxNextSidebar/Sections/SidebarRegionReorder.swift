import CoreGraphics

/// What a region drag moves: one item, or a section by its header.
nonisolated enum SidebarRegionDragSubject: Hashable, Sendable {
    case item(LayoutItemID)
    case section(LayoutSectionID)
}

/// The in-place reorder of the item sections (R77).
nonisolated enum SidebarRegionReorder {
    static func move(_ subject: SidebarRegionDragSubject, at point: CGPoint, display: SidebarRegionLayout,
                            sections: [LayoutSection]) -> [LayoutSection]? { nil }

    static func op(for subject: SidebarRegionDragSubject, shown: [LayoutSection], document: SidebarLayoutDocument) -> SidebarLayoutOp? { nil }
}
