public import Foundation

/// The split-layout tree for one workspace in the `system.tree` snapshot.
///
/// `system.tree`'s `panes` array is FLAT — it lists a workspace's panes in
/// order but discards how they are arranged: which splits are vertical vs
/// horizontal, their ratios, and their nesting. That geometry is live in the
/// workspace's bonsplit controller (`treeSnapshot()`); this type carries it
/// onto the wire so a consumer (e.g. `cl workspace` save/relaunch) can
/// recreate the real layout instead of falling back to a flat guess.
///
/// Pane leaves reference the SAME pane `UUID` that appears in the flat `panes`
/// array, so a consumer joins the two by id/ref rather than by position.
///
/// The emitted JSON mirrors the shape the `--layout` flag ACCEPTS
/// (`{direction, split, children}` for a split; a `{pane: …}` leaf otherwise),
/// so the tree cmux emits and the layout cmux ingests are one schema read two
/// ways. Kept free of any Bonsplit type so this low-level socket package gains
/// no dependency on the pane engine; the app maps `ExternalTreeNode` into this
/// at capture time.
public indirect enum ControlSystemTreeLayoutNode: Sendable, Equatable {
    /// A leaf: one pane, identified by the pane `UUID` also present in the
    /// workspace's flat `panes` array.
    case pane(paneID: UUID)

    /// A split of exactly two children along `orientation`
    /// ("horizontal" | "vertical") at `ratio` (the divider position, 0…1).
    case split(
        orientation: String,
        ratio: Double,
        first: ControlSystemTreeLayoutNode,
        second: ControlSystemTreeLayoutNode
    )
}
