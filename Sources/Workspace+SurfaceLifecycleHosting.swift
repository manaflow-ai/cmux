import Bonsplit
import CmuxWorkspaces
import CoreGraphics
import Foundation

/// `Workspace` is the live host for its `SurfaceLifecycleCoordinator`. Every
/// member reads the authoritative `BonsplitController` split tree and the
/// workspace's surface-id-to-panel-id mapping, reproducing the reads the legacy
/// Panel-Operations bodies performed inline. The one mutation
/// (``applySplitDividerPosition(_:forSplit:)``) mirrors the legacy external
/// divider write. The coordinator is held by `Workspace` and references this
/// host weakly, so there is no retain cycle.
extension Workspace: SurfaceLifecycleHosting {
    func surfaceId(forPanelId panelId: UUID) -> TabID? {
        surfaceIdFromPanelId(panelId)
    }

    var allBonsplitPaneIds: [PaneID] {
        bonsplitController.allPaneIds
    }

    func tabs(inPane paneId: PaneID) -> [Bonsplit.Tab] {
        bonsplitController.tabs(inPane: paneId)
    }

    func treeSnapshot() -> ExternalTreeNode {
        bonsplitController.treeSnapshot()
    }

    func layoutSnapshot() -> LayoutSnapshot {
        bonsplitController.layoutSnapshot()
    }

    @discardableResult
    func applySplitDividerPosition(_ position: CGFloat, forSplit splitId: UUID) -> Bool {
        bonsplitController.setDividerPosition(position, forSplit: splitId, fromExternal: true)
    }

    func surfaceLifecycleProfileDefinitionExists(id: UUID) -> Bool {
        BrowserProfileStore.shared.profileDefinition(id: id) != nil
    }

    var surfaceLifecycleEffectiveLastUsedProfileID: UUID {
        BrowserProfileStore.shared.effectiveLastUsedProfileID
    }

    var surfaceLifecyclePreferredBrowserProfileID: UUID? {
        preferredBrowserProfileID
    }

    func surfaceLifecycleSetPreferredBrowserProfileID(_ profileID: UUID?) {
        preferredBrowserProfileID = profileID
    }

    func surfaceLifecycleSourcePanelProfileID(panelId: UUID) -> UUID? {
        browserPanel(for: panelId)?.profileID
    }
}
