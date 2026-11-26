import Foundation

/// Where a Move Workspace verb puts an item of a band section (a tile or top row of Pinned,
/// which has no list row) among that section's items (``SidebarLayoutDocument/bandMove(_:_:)``).
public nonisolated enum SidebarBandPlacement: Hashable, Sendable {
    /// Move Up (-1) or Down (+1): one place, next to its neighbor. Stays at either end.
    case step(Int)
    /// Move to Top: first, after any leading Home item (the pinned block's top is just under Home).
    case top
    /// Move to Bottom: last.
    case bottom
    /// Move Above: right before the item with this id, in the same section.
    case above(String)
    /// Move Below: right after the item with this id, in the same section.
    case below(String)
}
