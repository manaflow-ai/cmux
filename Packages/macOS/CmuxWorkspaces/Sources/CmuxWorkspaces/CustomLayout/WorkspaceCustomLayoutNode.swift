public import Bonsplit

/// A resolved cmux.json custom-layout tree the ``WorkspaceLayoutCoordinator``
/// walks when applying a `layout` block to a freshly created workspace.
///
/// This is the package-side, `Sendable` value the coordinator orchestrates over.
/// It is a faithful one-for-one image of the app-target `CmuxLayoutNode`
/// (decoded from `cmux.json`), translated at the workspace boundary by the
/// `applyCustomLayout` forwarding shim. The app-target Codable types
/// (`CmuxLayoutNode`/`CmuxSplitDefinition`/`CmuxPaneDefinition`) own the wire
/// format and stay app-side; this type carries only the already-resolved fields
/// the layout walk reads (`splitOrientation`, `clampedSplitPosition`,
/// `surfaces`), so the coordinator never imports the app target and the wire
/// format is unaffected.
public indirect enum WorkspaceCustomLayoutNode: Sendable {
    /// A leaf pane holding one or more surfaces, in declaration order.
    case pane(surfaces: [WorkspaceCustomSurface])

    /// A split with exactly two children, an orientation, and an already-clamped
    /// divider position in `0.1...0.9` (the app-target
    /// `CmuxSplitDefinition.clampedSplitPosition`).
    case split(
        orientation: SplitOrientation,
        clampedSplitPosition: Double,
        children: [WorkspaceCustomLayoutNode]
    )
}
