import Foundation

extension CloudTreeNode.Kind {
    /// New resources and terminal sections start closed; all other groups
    /// remain open unless the person explicitly collapses them.
    var isExpandedByDefault: Bool {
        switch self {
        case .terminalsPool, .resourcesPool:
            return false
        default:
            return true
        }
    }
}

extension CloudTreeNodeBuilder {
    /// Builds the final Resources section for every Cloud machine.
    static func resourcesGroupNode(
        machine: SurfaceMachineID,
        snapshot: MachineSnapshot,
        now: Date
    ) -> CloudTreeNode {
        let section = CloudTreeMachineResourceSection(machine: snapshot, now: now)
        return CloudTreeNode(
            id: nodeID(resourcesPool: machine),
            kind: .resourcesPool(machine: machine, count: section.rows.count),
            children: section.rows.map { row in
                CloudTreeNode(
                    id: nodeID(resource: machine, metric: row.metric),
                    kind: .resource(machine: machine, row: row)
                )
            }
        )
    }
}
