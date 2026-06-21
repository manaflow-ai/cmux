public import Bonsplit
import Foundation

/// Owns the bonsplit tab context-menu command logic for one workspace: the
/// tab-list slicing (close-to-left/right/others), the surface-creation index
/// math (new terminal/browser to the right of the anchor), the
/// move-destination prefix-encoding and routing, and the per-action dispatch.
/// Lifted one-for-one from the `Workspace` private helpers (`tabIdsToLeft`,
/// `tabIdsToRight`, `tabIdsToCloseOthers`, `closeTabs`, `createTerminalToRight`,
/// `createBrowserToRight`, `copyIdentifiersToPasteboard`, `promptRenamePanel`,
/// `bonsplitTabMoveDestinations`, `moveBonsplitTab`, `showMoveTabFailureAlert`).
///
/// Reads the workspace's ``WorkspaceSurfaceListModel`` directly for the
/// per-pane tab order (so the close-to-left/right/others slicing stays in the
/// package) and forwards every irreducible app-coupled effect — surface
/// resolution/creation/reorder/close, NSAlert presentation, clipboard write,
/// and the `AppDelegate` cross-workspace move — through
/// ``WorkspaceContextMenuHosting``.
///
/// `@MainActor` because every entry point is a bonsplit menu action on the main
/// actor and the surface model + host both live there; co-locating removes any
/// bridging (mirrors the sibling workspace coordinators' isolation ruling).
@MainActor
public final class WorkspaceContextMenuCoordinator {
    private let surfaceList: WorkspaceSurfaceListModel
    private weak var host: (any WorkspaceContextMenuHosting)?

    /// The bonsplit destination id for the "move to a brand-new workspace" item.
    private static let moveNewWorkspaceDestinationId = "new-workspace"
    /// The prefix encoding an existing-workspace id into a bonsplit destination id.
    private static let moveExistingWorkspacePrefix = "workspace:"

    /// Creates the coordinator over the workspace's surface-list model.
    public init(surfaceList: WorkspaceSurfaceListModel) {
        self.surfaceList = surfaceList
    }

    /// Attaches the workspace-side host that performs the app-coupled effects.
    public func attach(host: any WorkspaceContextMenuHosting) {
        self.host = host
    }

    // MARK: - Close slicing (legacy tabIdsToLeft/Right/CloseOthers + closeTabs)

    /// Tab ids in tab order strictly before `anchorTabId` in `paneId`
    /// (legacy `Workspace.tabIdsToLeft(of:inPane:)`).
    public func tabIdsToLeft(of anchorTabId: TabID, inPane paneId: PaneID) -> [TabID] {
        surfaceList.surfaceIdsToLeft(of: anchorTabId.uuid, inPaneId: paneId.id).map { TabID(uuid: $0) }
    }

    /// Tab ids in tab order strictly after `anchorTabId` in `paneId`
    /// (legacy `Workspace.tabIdsToRight(of:inPane:)`).
    public func tabIdsToRight(of anchorTabId: TabID, inPane paneId: PaneID) -> [TabID] {
        surfaceList.surfaceIdsToRight(of: anchorTabId.uuid, inPaneId: paneId.id).map { TabID(uuid: $0) }
    }

    /// Every tab id in `paneId` except `anchorTabId`, in tab order
    /// (legacy `Workspace.tabIdsToCloseOthers(of:inPane:)`).
    public func tabIdsToCloseOthers(of anchorTabId: TabID, inPane paneId: PaneID) -> [TabID] {
        surfaceList.surfaceIdsToCloseOthers(of: anchorTabId.uuid, inPaneId: paneId.id).map { TabID(uuid: $0) }
    }

    /// Closes every tab to the left of `anchorTabId` in `paneId`
    /// (legacy `case .closeToLeft`).
    public func closeTabsToLeft(of anchorTabId: TabID, inPane paneId: PaneID) {
        host?.closeTabsFromContextMenu(tabIdsToLeft(of: anchorTabId, inPane: paneId), skipPinned: true)
    }

    /// Closes every tab to the right of `anchorTabId` in `paneId`
    /// (legacy `case .closeToRight`).
    public func closeTabsToRight(of anchorTabId: TabID, inPane paneId: PaneID) {
        host?.closeTabsFromContextMenu(tabIdsToRight(of: anchorTabId, inPane: paneId), skipPinned: true)
    }

    /// Closes every other tab in `paneId` (legacy `case .closeOthers`).
    public func closeOtherTabs(than anchorTabId: TabID, inPane paneId: PaneID) {
        host?.closeTabsFromContextMenu(tabIdsToCloseOthers(of: anchorTabId, inPane: paneId), skipPinned: true)
    }

    // MARK: - Rename / clipboard

    /// Opens the rename-tab prompt for `tabId` (legacy `case .rename`).
    public func renameTab(_ tabId: TabID) {
        host?.presentRenamePrompt(tabId: tabId)
    }

    /// Copies the workspace/pane/surface identifiers for `tabId` to the
    /// pasteboard (legacy `case .copyIdentifiers`).
    public func copyIdentifiers(for tabId: TabID) {
        guard let panelId = host?.panelId(forSurfaceId: tabId) else { return }
        host?.copySurfaceIdentifiersToPasteboard(surfaceId: panelId)
    }

    // MARK: - Create to the right (legacy createTerminalToRight/createBrowserToRight)

    /// Creates a new terminal surface immediately to the right of `anchorTabId`
    /// in `paneId` (legacy `Workspace.createTerminalToRight(of:inPane:)`).
    public func createTerminalToRight(of anchorTabId: TabID, inPane paneId: PaneID) {
        guard let host else { return }
        let targetIndex = host.insertionIndexToRight(of: anchorTabId, inPane: paneId)
        let sourcePanelId = host.panelId(forSurfaceId: anchorTabId)
        guard let newPanelId = host.newTerminalSurface(
            inPane: paneId,
            workingDirectoryFallbackSourcePanelId: sourcePanelId
        ) else { return }
        host.reorderSurface(panelId: newPanelId, toIndex: targetIndex)
    }

    /// Creates a new browser surface immediately to the right of `anchorTabId`
    /// in `paneId` (legacy `Workspace.createBrowserToRight(of:inPane:)`).
    public func createBrowserToRight(of anchorTabId: TabID, inPane paneId: PaneID) {
        guard let host else { return }
        let targetIndex = host.insertionIndexToRight(of: anchorTabId, inPane: paneId)
        let anchorPanelId = host.panelId(forSurfaceId: anchorTabId)
        guard let newPanelId = host.newBrowserSurface(
            inPane: paneId,
            inheritingProfileFromPanelId: anchorPanelId
        ) else { return }
        host.reorderSurface(panelId: newPanelId, toIndex: targetIndex)
    }

    // MARK: - Move destinations (legacy bonsplitTabMoveDestinations/moveBonsplitTab)

    /// The "Move Tab To…" submenu destinations for `tabId`, with the optional
    /// "New Workspace" item first followed by the existing-workspace targets
    /// (legacy `Workspace.bonsplitTabMoveDestinations(for:)`). `newWorkspaceTitle`
    /// is the localized "New Workspace" label resolved app-side.
    public func moveDestinations(
        for tabId: TabID,
        newWorkspaceTitle: String
    ) -> [TabContextMoveDestination] {
        guard let host, let panelId = host.panelId(forSurfaceId: tabId) else { return [] }
        let workspaceTargets = host.workspaceMoveTargets(forBonsplitTab: tabId)
        var destinations: [TabContextMoveDestination] = []
        if host.canMoveSurfaceToNewWorkspace(panelId: panelId) {
            destinations.append(TabContextMoveDestination(
                id: Self.moveNewWorkspaceDestinationId,
                title: newWorkspaceTitle
            ))
        }
        destinations.append(contentsOf: workspaceTargets.map { target in
            TabContextMoveDestination(
                id: Self.moveExistingWorkspacePrefix + target.workspaceId.uuidString,
                title: target.label
            )
        })
        return destinations
    }

    /// Moves `tabId` to the bonsplit destination `destinationId`, presenting the
    /// move-failure alert when the move fails (legacy
    /// `Workspace.moveBonsplitTab(_:toMoveDestination:)`). Returns whether the
    /// move succeeded.
    @discardableResult
    public func moveTab(_ tabId: TabID, toMoveDestination destinationId: String) -> Bool {
        guard let host, let panelId = host.panelId(forSurfaceId: tabId) else { return false }

        let moved: Bool
        if destinationId == Self.moveNewWorkspaceDestinationId {
            moved = host.moveSurfaceToNewWorkspace(panelId: panelId)
        } else if destinationId.hasPrefix(Self.moveExistingWorkspacePrefix) {
            let rawWorkspaceId = destinationId.dropFirst(Self.moveExistingWorkspacePrefix.count)
            guard let workspaceId = UUID(uuidString: String(rawWorkspaceId)) else { return false }
            moved = host.moveSurface(panelId: panelId, toWorkspace: workspaceId)
        } else {
            moved = false
        }

        if !moved {
            host.presentMoveFailureAlert()
        }
        return moved
    }
}
