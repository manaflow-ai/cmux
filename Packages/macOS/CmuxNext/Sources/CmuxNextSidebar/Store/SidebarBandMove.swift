import Foundation

/// What a ``SidebarBandPlacement`` does to an item of a band section
/// (``SidebarLayoutDocument/bandMove(_:_:)``).
public nonisolated enum SidebarBandMove: Hashable, Sendable {
    /// The item is already there (the first item's Move to Top, the last one's Move Down):
    /// nothing to send, and nothing to refuse.
    case stays
    /// The item moves to `index` of `section`, counted without the item itself (the layout's
    /// `item.move`), which is `target` for the sidebar document (next to a neighbor).
    case move(section: LayoutSectionID, index: Int, target: SidebarDocTarget)

    /// The layout op that makes this move for item `id`; nil when it stays.
    public func layoutOp(_ id: LayoutItemID) -> SidebarLayoutOp? {
        guard case let .move(section, index, _) = self else { return nil }
        return .itemMove(id, section: section, index: index)
    }
}
