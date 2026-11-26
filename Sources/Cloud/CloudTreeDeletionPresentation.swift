import CmuxSurfaceCatalogModel
import Foundation

/// Per-outline selection/expansion recovery. Resource truth remains in the catalog;
/// this owner remembers only presentation that an optimistic removal displaced.
@MainActor
final class CloudTreeDeletionPresentation {
    private var hiddenRoots: [String: CloudTreeNode] = [:]
    /// Maps every displaced descendant to its hidden root once, so rollback
    /// selection recovery does not flatten each candidate subtree repeatedly.
    private var hiddenRootIDByNodeID: [String: String] = [:]
    private var recovery: (originalNodeID: String, fallbackNodeID: String?, rootID: String)?

    /// - Parameters:
    ///   - previous: The rows shown before this snapshot; hidden rows are remembered from here.
    ///   - next: The rows the catalog projects now (pending deletions already hidden).
    ///   - pending: Workspaces admitted for deletion but not yet confirmed, per machine.
    ///   - pendingMachines: Cloud machines whose delete may still roll back.
    ///   - selectedNodeID: The outline's current selection.
    /// - Returns: The selection to restore and the rows whose expansion state must survive,
    ///   including hidden rows so a rollback reopens them exactly as they were.
    func update(
        previous: [CloudTreeNode],
        next: [CloudTreeNode],
        pending: [SurfaceMachineID: Set<String>],
        pendingMachines: Set<String> = [],
        selectedNodeID: String?
    ) -> (selectedNodeID: String?, expansionNodes: [CloudTreeNode]) {
        let pendingIDs = Set(pending.flatMap { machine, ids in
            ids.map { CloudTreeNodeBuilder.nodeID(workspace: $0, machine: machine) }
        })
        let isHidden: (CloudTreeNode) -> Bool = { node in
            if case .machine(let machine, _) = node.kind { return pendingMachines.contains(machine.id) }
            return pendingIDs.contains(node.id)
        }
        let shown = CloudTreeNodeBuilder.flattened(previous)
        // A hidden machine owns the rows of hidden workspaces under it, so it is remembered last.
        for node in shown.filter({ !$0.isMachineRow }) + shown.filter(\.isMachineRow) where isHidden(node) {
            hiddenRoots[node.id] = node
            for descendant in CloudTreeNodeBuilder.flattened([node]) {
                hiddenRootIDByNodeID[descendant.id] = node.id
            }
        }
        hiddenRoots = hiddenRoots.filter { isHidden($0.value) }
        hiddenRootIDByNodeID = hiddenRootIDByNodeID.filter { hiddenRoots[$0.value] != nil }
        let nextIDs = Set(CloudTreeNodeBuilder.flattened(next).map(\.id))
        var selected = selectedNodeID
        if let saved = recovery {
            if selectedNodeID != saved.fallbackNodeID {
                recovery = nil // Never steal a newer user selection on rollback.
            } else if hiddenRoots[saved.rootID] == nil {
                if nextIDs.contains(saved.originalNodeID) { selected = saved.originalNodeID }
                recovery = nil
            }
        }
        if recovery == nil, let selectedID = selected, !nextIDs.contains(selectedID),
           let rootID = hiddenRootIDByNodeID[selectedID],
           let root = hiddenRoots[rootID] {
            // A hidden workspace hands its selection to its machine; a hidden machine has no row to take it.
            let fallback = root.isMachineRow ? nil : CloudTreeNodeBuilder.nodeID(machine: root.machine)
            recovery = (selectedID, fallback, root.id)
            selected = fallback
        }
        return (selected, next + Array(hiddenRoots.values))
    }
}
