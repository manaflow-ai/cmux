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

    private let defaults: any CloudTreeExpansionPersistence
    private var collapsedMachineIDs: Set<String>
    private var collapsedNodeIDs: Set<String>
    private var expandedNodeIDs: Set<String>
    private var missingNodePasses: [String: Int] = [:]
    private struct Batch {
        let machines: Set<String>
        let collapsed: Set<String>
        let expanded: Set<String>
    }
    private var batch: Batch?

    init(defaults: any CloudTreeExpansionPersistence = CloudTreeExpansionPreferences()) {
        self.defaults = defaults
        collapsedMachineIDs = Set(defaults.stringArray(forKey: Self.collapsedMachinesKey) ?? [])
        collapsedNodeIDs = Set(defaults.stringArray(forKey: Self.collapsedNodesKey) ?? [])
        expandedNodeIDs = Set(defaults.stringArray(forKey: Self.expandedNodesKey) ?? [])
        // Keep both stored sets until the next explicit choice can persist
        // every changed key. isExpanded gives a conflicting collapse priority.
    }

    func isExpanded(_ node: CloudTreeNode) -> Bool {
        // A machine's tab row has children only while a tab is open, and then
        // always shows them; its tabs, not a disclosure, open and close it.
        if case .machineDetailTabs = node.kind { return true }
        if node.isMachineRow {
            return !collapsedMachineIDs.contains(node.machine.rawValue)
        }
        if collapsedNodeIDs.contains(node.id) { return false }
        if expandedNodeIDs.contains(node.id) { return true }
        return node.kind.isExpandedByDefault
    }

    /// One native operation can explicitly change a subtree. Sort and persist
    /// each affected key once, after all of its callbacks have completed.
    func withBatch(_ action: () -> Void) {
        guard batch == nil else { action(); return }
        let previous = Batch(machines: collapsedMachineIDs, collapsed: collapsedNodeIDs, expanded: expandedNodeIDs)
        batch = previous
        defer {
            batch = nil
            if collapsedMachineIDs != previous.machines {
                defaults.setIfChanged(collapsedMachineIDs.sorted(), forKey: Self.collapsedMachinesKey)
            }
            if collapsedNodeIDs != previous.collapsed {
                defaults.setIfChanged(collapsedNodeIDs.sorted(), forKey: Self.collapsedNodesKey)
            }
            if expandedNodeIDs != previous.expanded {
                defaults.setIfChanged(expandedNodeIDs.sorted(), forKey: Self.expandedNodesKey)
            }
        }
        action()
    }

    func setExpanded(_ expanded: Bool, node: CloudTreeNode) {
        if case .machineDetailTabs = node.kind { return }
        if node.isMachineRow {
            let key = node.machine.rawValue
            let changed = expanded
                ? collapsedMachineIDs.remove(key) != nil
                : collapsedMachineIDs.insert(key).inserted
            if changed, batch == nil { defaults.setIfChanged(collapsedMachineIDs.sorted(), forKey: Self.collapsedMachinesKey) }
            return
        }
        let collapse = !expanded && node.kind.isExpandedByDefault
        let expand = expanded && !node.kind.isExpandedByDefault
        let collapsedChanged = collapse
            ? collapsedNodeIDs.insert(node.id).inserted : collapsedNodeIDs.remove(node.id) != nil
        let expandedChanged = expand
            ? expandedNodeIDs.insert(node.id).inserted : expandedNodeIDs.remove(node.id) != nil
        if collapsedChanged, batch == nil { defaults.setIfChanged(collapsedNodeIDs.sorted(), forKey: Self.collapsedNodesKey) }
        if expandedChanged, batch == nil { defaults.setIfChanged(expandedNodeIDs.sorted(), forKey: Self.expandedNodesKey) }
    }

    /// Drops expansion entries for rows that no longer exist after a catalog
    /// refresh, keeping persisted state bounded as machines and workspaces churn.
    func reconcile(nodes: [CloudTreeNode]) {
        let trackedIDs = collapsedMachineIDs.union(collapsedNodeIDs).union(expandedNodeIDs)
        guard !trackedIDs.isEmpty else { return }
        let flattened = CloudTreeNodeBuilder.flattened(nodes)
        let nodeIDs = Set(flattened.filter { !$0.isMachineRow }.map(\.id))
        let machineIDs = Set(flattened.filter(\.isMachineRow).map { $0.machine.rawValue })
        let previousMachines = collapsedMachineIDs
        let previousCollapsed = collapsedNodeIDs
        let previousExpanded = expandedNodeIDs
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
        guard batch == nil else { return }
        if collapsedMachineIDs != previousMachines {
            defaults.setIfChanged(collapsedMachineIDs.sorted(), forKey: Self.collapsedMachinesKey)
        }
        if collapsedNodeIDs != previousCollapsed {
            defaults.setIfChanged(collapsedNodeIDs.sorted(), forKey: Self.collapsedNodesKey)
        }
        if expandedNodeIDs != previousExpanded {
            defaults.setIfChanged(expandedNodeIDs.sorted(), forKey: Self.expandedNodesKey)
        }
    }

    /// A refresh may publish an empty or partial tree; three absent passes
    /// distinguish that transient state from a confirmed deletion.
    private static let missingNodePassThreshold = 3
}
