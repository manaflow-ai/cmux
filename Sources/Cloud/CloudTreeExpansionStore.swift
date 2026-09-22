import Foundation

/// Remembers which Cloud outline nodes the person expanded or collapsed.
///
/// Machines default to expanded and their collapse persists per machine id. A
/// new machine section can have a closed initial default without losing an
/// explicit user expansion during a refresh.
@MainActor
final class CloudTreeExpansionStore {
    private static let collapsedMachinesKey = "cloudTree.collapsedMachineIDs"
    private static let collapsedNodesKey = "cloudTree.collapsedNodeIDs"
    private static let expandedNodesKey = "cloudTree.expandedNodeIDs"

    private let defaults: UserDefaults
    private var collapsedMachineIDs: Set<String>
    private var collapsedNodeIDs: Set<String>
    private var expandedNodeIDs: Set<String>
    private var missingNodePasses: [String: Int] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        collapsedMachineIDs = Set(defaults.stringArray(forKey: Self.collapsedMachinesKey) ?? [])
        collapsedNodeIDs = Set(defaults.stringArray(forKey: Self.collapsedNodesKey) ?? [])
        expandedNodeIDs = Set(defaults.stringArray(forKey: Self.expandedNodesKey) ?? [])
        // If an interrupted write left a node in both sets, the explicit
        // collapsed choice is the safe migration result.
        expandedNodeIDs.subtract(collapsedNodeIDs)
    }

    func isExpanded(_ node: CloudTreeNode) -> Bool {
        if node.isMachineRow {
            return !collapsedMachineIDs.contains(node.machine.rawValue)
        }
        if collapsedNodeIDs.contains(node.id) { return false }
        if expandedNodeIDs.contains(node.id) { return true }
        return node.kind.isExpandedByDefault
    }

    func setExpanded(_ expanded: Bool, node: CloudTreeNode) {
        if node.isMachineRow {
            let key = node.machine.rawValue
            if expanded { collapsedMachineIDs.remove(key) } else { collapsedMachineIDs.insert(key) }
            defaults.set(Array(collapsedMachineIDs).sorted(), forKey: Self.collapsedMachinesKey)
            return
        } else if expanded {
            collapsedNodeIDs.remove(node.id)
            if !node.kind.isExpandedByDefault { expandedNodeIDs.insert(node.id) }
        } else {
            expandedNodeIDs.remove(node.id)
            if node.kind.isExpandedByDefault { collapsedNodeIDs.insert(node.id) }
        }
        defaults.set(Array(collapsedNodeIDs), forKey: Self.collapsedNodesKey)
        defaults.set(Array(expandedNodeIDs), forKey: Self.expandedNodesKey)
    }

    /// Drops expansion entries for rows that no longer exist after a catalog
    /// refresh, keeping persisted state bounded as machines and workspaces churn.
    func reconcile(nodes: [CloudTreeNode]) {
        let flattened = CloudTreeNodeBuilder.flattened(nodes)
        let nodeIDs = Set(flattened.filter { !$0.isMachineRow }.map(\.id))
        let machineIDs = Set(flattened.filter(\.isMachineRow).map { $0.machine.rawValue })
        let previousMachines = collapsedMachineIDs
        let previousCollapsed = collapsedNodeIDs
        let previousExpanded = expandedNodeIDs
        let trackedIDs = collapsedMachineIDs.union(collapsedNodeIDs).union(expandedNodeIDs)
        let presentIDs = machineIDs.union(nodeIDs)
        var removedIDs: Set<String> = []
        for id in trackedIDs {
            guard !presentIDs.contains(id) else {
                missingNodePasses.removeValue(forKey: id)
                continue
            }
            let passes = min((missingNodePasses[id] ?? 0) + 1, Self.missingNodePassThreshold)
            if passes == Self.missingNodePassThreshold {
                removedIDs.insert(id)
                missingNodePasses.removeValue(forKey: id)
            } else {
                missingNodePasses[id] = passes
            }
        }
        collapsedMachineIDs.subtract(removedIDs)
        collapsedNodeIDs.subtract(removedIDs)
        expandedNodeIDs.subtract(removedIDs)
        guard collapsedMachineIDs != previousMachines
            || collapsedNodeIDs != previousCollapsed
            || expandedNodeIDs != previousExpanded else { return }
        defaults.set(Array(collapsedMachineIDs).sorted(), forKey: Self.collapsedMachinesKey)
        defaults.set(Array(collapsedNodeIDs), forKey: Self.collapsedNodesKey)
        defaults.set(Array(expandedNodeIDs), forKey: Self.expandedNodesKey)
    }

    /// A refresh may publish an empty or partial tree; three absent passes
    /// distinguish that transient state from a confirmed deletion.
    private static let missingNodePassThreshold = 3
}
