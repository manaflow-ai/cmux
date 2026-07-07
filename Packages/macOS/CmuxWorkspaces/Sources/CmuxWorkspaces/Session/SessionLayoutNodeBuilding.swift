public import Foundation

/// Seam satisfied by the app's `SessionWorkspaceLayoutSnapshot` enum so the
/// package can *build* a persisted layout tree from a live Bonsplit
/// `ExternalTreeNode` without owning the wire format or the concrete pane/split
/// DTOs.
///
/// This is the construction counterpart to ``SessionLayoutPruning`` (which only
/// reads and reconstructs an already-persisted tree). ``SessionRestoreCoordinator``
/// walks the live tree, resolves each pane's panel ids through the host, and
/// asks the conformer to mint the matching leaf and split nodes. The conformer
/// maps the package's orientation flag onto its own `SessionSplitOrientation`
/// enum, keeping the persisted enum's `Codable` shape owned by the app target.
///
/// The reconstructors are static/instance to mirror the legacy in-file
/// `Workspace.sessionLayoutSnapshot(from:)` which constructed
/// `.pane(SessionPaneLayoutSnapshot(...))` and
/// `.split(SessionSplitLayoutSnapshot(...))` directly; the package now produces
/// the identical values and the conformer wraps them, byte-faithfully.
public protocol SessionLayoutNodeBuilding: Sendable {
    /// Builds a leaf pane node from the resolved panel-id list, selection, and
    /// full-width mode, reproducing the legacy
    /// `.pane(SessionPaneLayoutSnapshot(panelIds:selectedPanelId:isFullWidthTabMode:))`.
    static func sessionLayoutBuiltPane(
        panelIds: [UUID],
        selectedPanelId: UUID?,
        isFullWidthTabMode: Bool?
    ) -> Self

    /// Builds a split node from its orientation, divider position, and the two
    /// already-built children, reproducing the legacy
    /// `.split(SessionSplitLayoutSnapshot(orientation:dividerPosition:first:second:))`.
    ///
    /// `isVertical` carries the legacy decision
    /// `split.orientation.lowercased() == "vertical"`; the conformer maps it to
    /// its persisted `SessionSplitOrientation` (`.vertical` when true, otherwise
    /// `.horizontal`).
    static func sessionLayoutBuiltSplit(
        isVertical: Bool,
        dividerPosition: Double,
        first: Self,
        second: Self
    ) -> Self
}
