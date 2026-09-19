import Foundation

/// Per-outline selection/expansion recovery. Resource truth remains in the catalog;
/// this owner remembers only presentation that an optimistic removal displaced.
@MainActor
final class CloudTreeDeletionPresentation {
    private var hiddenRoots: [String: CloudTreeNode] = [:]
    /// Maps every displaced descendant to its hidden root once, so rollback
    /// selection recovery does not flatten each candidate subtree repeatedly.
    private var hiddenRootIDByNodeID: [String: String] = [:]
    private var recovery: (originalNodeID: String, fallbackNodeID: String, rootID: String)?

    /// - Parameters:
    ///   - previous: The rows shown before this snapshot; hidden workspace rows are remembered from here.
    ///   - next: The rows the catalog projects now (pending deletions already hidden).
    ///   - pending: Workspaces admitted for deletion but not yet confirmed, per machine.
    ///   - selectedNodeID: The outline's current selection.
    /// - Returns: The selection to restore and the rows whose expansion state must survive,
    ///   including hidden rows so a rollback reopens them exactly as they were.
    func update(
        previous: [CloudTreeNode],
        next: [CloudTreeNode],
        pending: [SurfaceMachineID: Set<String>],
        selectedNodeID: String?
    ) -> (selectedNodeID: String?, expansionNodes: [CloudTreeNode]) {
        let pendingIDs = Set(pending.flatMap { machine, ids in
            ids.map { CloudTreeNodeBuilder.nodeID(workspace: $0, machine: machine) }
        })
        for node in CloudTreeNodeBuilder.flattened(previous) where pendingIDs.contains(node.id) {
            hiddenRoots[node.id] = node
            for descendant in CloudTreeNodeBuilder.flattened([node]) {
                hiddenRootIDByNodeID[descendant.id] = node.id
            }
        }
        let nextIDs = Set(CloudTreeNodeBuilder.flattened(next).map(\.id))
        var selected = selectedNodeID
        if let saved = recovery {
            if selectedNodeID != saved.fallbackNodeID {
                recovery = nil // Never steal a newer user selection on rollback.
            } else if !pendingIDs.contains(saved.rootID) {
                if nextIDs.contains(saved.originalNodeID) { selected = saved.originalNodeID }
                recovery = nil
            }
        }
        if recovery == nil, let selectedID = selected, !nextIDs.contains(selectedID),
           let rootID = hiddenRootIDByNodeID[selectedID],
           let root = hiddenRoots[rootID] {
            let fallback = CloudTreeNodeBuilder.nodeID(machine: root.machine)
            recovery = (selectedID, fallback, root.id)
            selected = fallback
        }
        hiddenRoots = hiddenRoots.filter { pendingIDs.contains($0.key) }
        hiddenRootIDByNodeID = hiddenRootIDByNodeID.filter { pendingIDs.contains($0.value) }
        return (selected, next + Array(hiddenRoots.values))
    }
}
