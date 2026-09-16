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
        } else if expanded {
            collapsedNodeIDs.remove(node.id)
            if !node.kind.isExpandedByDefault { expandedNodeIDs.insert(node.id) }
        } else {
            expandedNodeIDs.remove(node.id)
            if node.kind.isExpandedByDefault { collapsedNodeIDs.insert(node.id) }
        }
        defaults.set(Array(collapsedNodeIDs).sorted(), forKey: Self.collapsedNodesKey)
        defaults.set(Array(expandedNodeIDs).sorted(), forKey: Self.expandedNodesKey)
    }
}
