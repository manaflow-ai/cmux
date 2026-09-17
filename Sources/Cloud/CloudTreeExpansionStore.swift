import Foundation

/// Remembers which Cloud outline nodes the person collapsed.
///
/// Machines default to expanded and their collapse persists per machine id (a
/// tree that opens closed shows nothing new). Nested rows (groups, workspaces)
/// also default to expanded and only remember collapses for the panel's lifetime.
@MainActor
final class CloudTreeExpansionStore {
    private static let collapsedMachinesKey = "cloudTree.collapsedMachineIDs"

    private let defaults: UserDefaults
    private var collapsedMachineIDs: Set<String>
    private var collapsedNodeIDs: Set<String> = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        collapsedMachineIDs = Set(defaults.stringArray(forKey: Self.collapsedMachinesKey) ?? [])
    }

    func isExpanded(_ node: CloudTreeNode) -> Bool {
        if node.isMachineRow {
            return !collapsedMachineIDs.contains(node.machine.rawValue)
        }
        return !collapsedNodeIDs.contains(node.id)
    }

    func setExpanded(_ expanded: Bool, node: CloudTreeNode) {
        if node.isMachineRow {
            let key = node.machine.rawValue
            if expanded { collapsedMachineIDs.remove(key) } else { collapsedMachineIDs.insert(key) }
            defaults.set(Array(collapsedMachineIDs).sorted(), forKey: Self.collapsedMachinesKey)
        } else {
            if expanded { collapsedNodeIDs.remove(node.id) } else { collapsedNodeIDs.insert(node.id) }
        }
    }
}
