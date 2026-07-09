public import Foundation
public import Bonsplit

/// The workspace-side seam ``SurfaceLifecycleCoordinator`` reads (and, for the
/// one divider write, drives) the live split tree through.
///
/// **Why a synchronous read-only/one-write protocol and not value snapshots.**
/// Every resolver lifted into the coordinator
/// (``SurfaceLifecycleCoordinator/paneId(forPanelId:)``,
/// ``SurfaceLifecycleCoordinator/indexInPane(forPanelId:)``,
/// ``SurfaceLifecycleCoordinator/preferredRightSideTargetPane(fromPanelId:)``,
/// ``SurfaceLifecycleCoordinator/topRightBrowserReusePane()``,
/// ``SurfaceLifecycleCoordinator/applyInitialSplitDividerPosition(_:sourcePaneId:newPaneId:)``)
/// is one MainActor turn that must observe the authoritative `BonsplitController`
/// split tree, pane list, and per-pane tab order exactly as the legacy
/// `Workspace` method bodies did. The split tree and tab membership are owned by
/// `BonsplitController`; the surface-id-to-panel-id mapping is owned by the
/// workspace. The coordinator reads them through this seam so it never holds the
/// app-target `Workspace`, while the values it sees are always the live state.
///
/// The seam speaks bonsplit value types (`PaneID`, `ExternalTreeNode`,
/// `LayoutSnapshot`) directly because `CmuxWorkspaces` already depends on
/// `Bonsplit`; the geometry recursions over `ExternalTreeNode` live in
/// `CmuxPanes`. The single mutation
/// (``applySplitDividerPosition(_:forSplit:)``) mirrors the legacy
/// `bonsplitController.setDividerPosition(_:forSplit:fromExternal: true)` write.
@MainActor
public protocol SurfaceLifecycleHosting: AnyObject {
    /// Resolves the bonsplit surface id (`TabID.uuid`) owning the given panel id,
    /// or `nil` when the panel maps to no surface (legacy
    /// `Workspace.surfaceIdFromPanelId`).
    func surfaceId(forPanelId panelId: UUID) -> TabID?

    /// Every pane id, unordered (legacy `bonsplitController.allPaneIds`). Named
    /// distinctly from the `[UUID]`-typed `allPaneIds` that the host already
    /// exposes for `WorkspaceSurfaceTreeReading`, so the two witnesses do not
    /// collide on the concrete `Workspace`.
    var allBonsplitPaneIds: [PaneID] { get }

    /// The pane's tabs in tab order (legacy `bonsplitController.tabs(inPane:)`).
    func tabs(inPane paneId: PaneID) -> [Bonsplit.Tab]

    /// The current split-tree snapshot (legacy
    /// `bonsplitController.treeSnapshot()`).
    func treeSnapshot() -> ExternalTreeNode

    /// The current pixel-coordinate layout snapshot (legacy
    /// `bonsplitController.layoutSnapshot()`).
    func layoutSnapshot() -> LayoutSnapshot

    /// Applies an external divider position to the split with the given id,
    /// returning whether it took (legacy
    /// `bonsplitController.setDividerPosition(_:forSplit:fromExternal: true)`).
    @discardableResult
    func applySplitDividerPosition(_ position: CGFloat, forSplit splitId: UUID) -> Bool

    /// Whether a browser profile with the given id is currently defined, mirroring
    /// the legacy `BrowserProfileStore.shared.profileDefinition(id:) != nil` guard
    /// that gated every profile-id resolution. The profile store is an app-target
    /// singleton, so the existence check stays behind the seam.
    func surfaceLifecycleProfileDefinitionExists(id: UUID) -> Bool

    /// The profile id a fresh browser surface should fall back to when no
    /// preferred or source profile applies (legacy
    /// `BrowserProfileStore.shared.effectiveLastUsedProfileID`).
    var surfaceLifecycleEffectiveLastUsedProfileID: UUID { get }

    /// The workspace's currently preferred browser profile id, the third tier of
    /// `Workspace.resolvedNewBrowserProfileID` and the value
    /// `Workspace.setPreferredBrowserProfileID` writes (the workspace owns the
    /// stored `preferredBrowserProfileID`, which is `private(set)`).
    var surfaceLifecyclePreferredBrowserProfileID: UUID? { get }

    /// Writes the workspace's preferred browser profile id (legacy
    /// `Workspace.preferredBrowserProfileID = …`). The property is `private(set)`
    /// on the workspace, so the one mutation goes through the seam; it carries no
    /// Combine subscriber, so no observer-parity bridge is needed.
    func surfaceLifecycleSetPreferredBrowserProfileID(_ profileID: UUID?)

    /// The profile id of the browser panel owning `panelId`, or `nil` when that
    /// panel is not a browser panel (legacy
    /// `browserPanel(for: sourcePanelId)?.profileID`). The app-target
    /// `BrowserPanel` type never crosses into the package; only its `UUID`
    /// profile id does.
    func surfaceLifecycleSourcePanelProfileID(panelId: UUID) -> UUID?
}
