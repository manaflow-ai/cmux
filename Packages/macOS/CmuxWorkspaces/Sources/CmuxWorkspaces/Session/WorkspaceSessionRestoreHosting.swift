public import Bonsplit
public import Foundation

/// The window-side seam the ``SessionRestoreCoordinator`` drives for the
/// persisted-layout (de)serialization bridge: the live surface-id → panel-id
/// map it reads when snapshotting the Bonsplit tree, and the single divider
/// mutation it issues when re-applying a restored layout's divider positions.
///
/// **Why a synchronous two-way protocol.** Both legs run inside one MainActor
/// turn during a session snapshot/restore. Snapshotting reads
/// ``surfaceIdToPanelId`` while walking a `treeSnapshot()` the caller already
/// captured; restoring walks the persisted layout and the live tree in
/// lockstep, issuing one `BonsplitController.setDividerPosition(_:forSplit:fromExternal:)`
/// per matching split. Pushing either leg through a stream would open a
/// suspension window in which pane/tab mutations could interleave, observably
/// changing which dividers land. The coordinator stays `@MainActor` and calls
/// the host synchronously; the per-window `Workspace` is the single conformer.
/// This mirrors the ``WorkspaceHandoffHosting`` / ``FocusedSurfaceHosting``
/// seams.
///
/// The conformer owns the `BonsplitController` and the pane-tree sub-model that
/// holds the surface-id map; the package never imports the `Workspace` god type.
@MainActor
public protocol WorkspaceSessionRestoreHosting: AnyObject {
    /// The live Bonsplit surface-id (`TabID`) → owning panel-id map, read while
    /// resolving each persisted pane's panel ids (legacy
    /// `Workspace.surfaceIdToPanelId`, stored in the pane-tree sub-model).
    var surfaceIdToPanelId: [TabID: UUID] { get }

    /// Whether the live Bonsplit pane is currently in full-width tab mode,
    /// read while building a persisted layout snapshot.
    func sessionFullWidthTabMode(forPaneId paneId: UUID) -> Bool

    /// Applies a restored divider position to the live split, forwarding to
    /// `BonsplitController.setDividerPosition(_:forSplit:fromExternal:)` with
    /// `fromExternal: true` exactly as the legacy
    /// `Workspace.applySessionDividerPositions` did. A no-op when the split is
    /// gone, mirroring the legacy controller's optional handling.
    func applySessionDividerPosition(_ position: CGFloat, forSplit splitID: UUID)
}
