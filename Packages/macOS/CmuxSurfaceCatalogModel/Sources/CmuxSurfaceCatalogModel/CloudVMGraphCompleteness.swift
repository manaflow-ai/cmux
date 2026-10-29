import Foundation

/// Validates that an accepted daemon graph has enough catalog metadata to reconcile panes.
public struct CloudVMGraphCompleteness: Sendable {
    private struct View: Hashable {
        let resource: SurfaceResourceID
        let tab: String
        let workspace: String
        let screen: String?
        let pane: String?
    }

    private let incompleteWorkspaceIDs: Set<String>
    private let hasUnresolvedOwner: Bool

    /// Checks the live tab joins once for all workspaces in a daemon graph.
    ///
    /// - Parameters:
    ///   - state: The accepted daemon graph.
    ///   - resources: Catalog rows derived from that graph, including pending receipts.
    ///
    /// Terminal reverse references may retain old tab IDs after a detach or exit.
    /// Only live rows in ``CloudVMState/tabs`` attest to current membership.
    /// Construction is linear in the number of resources, views and live tabs;
    /// each subsequent workspace check is constant time.
    ///
    /// ```swift
    /// let completeness = CloudVMGraphCompleteness(state: state, resources: resources)
    /// if completeness.isComplete(workspaceID: workspaceID) {
    ///     // Reconcile this workspace's panes from the accepted graph.
    /// }
    /// ```
    public init(state: CloudVMState, resources: [SurfaceResource]) {
        var views = Set<View>()
        for resource in resources where resource.machine == state.machine {
            for view in resource.remoteViews ?? [] {
                views.insert(View(resource: resource.id, tab: view.tabID, workspace: view.workspace.id,
                                  screen: view.screenID, pane: view.paneID))
            }
        }
        var incomplete = Set<String>()
        var unresolvedOwner = false
        for tab in state.tabs {
            guard let pane = state.lookupIndex.pane(id: tab.paneID),
                  let screen = state.lookupIndex.screen(id: pane.screenID),
                  state.lookupIndex.workspace(id: screen.workspaceID) != nil else {
                unresolvedOwner = true
                continue
            }
            let kind: SurfaceResourceKind
            switch tab.contentKind {
            case "terminal": kind = .terminal
            case "browser": kind = .browser
            case "display", "screen": kind = .display
            default:
                incomplete.insert(screen.workspaceID)
                continue
            }
            let resourceID = SurfaceResourceID(machine: state.machine, kind: kind, key: tab.contentID)
            if !views.contains(View(resource: resourceID, tab: tab.id, workspace: screen.workspaceID,
                                    screen: screen.id, pane: pane.id)) {
                incomplete.insert(screen.workspaceID)
            }
        }
        incompleteWorkspaceIDs = incomplete
        hasUnresolvedOwner = unresolvedOwner
    }

    /// Returns whether a workspace has all the metadata needed to reconcile its live tabs.
    ///
    /// - Parameter workspaceID: The workspace to check, or nil to check the whole machine.
    /// - Returns: False when live tab ownership or a catalog view is unresolved.
    public func isComplete(workspaceID: String? = nil) -> Bool {
        guard !hasUnresolvedOwner else { return false }
        return workspaceID.map { !incompleteWorkspaceIDs.contains($0) } ?? incompleteWorkspaceIDs.isEmpty
    }
}
