import Foundation

extension CloudTreeNode.Kind {
    /// Readings describe a machine without representing a selectable pane.
    var isSelectable: Bool {
        switch self {
        case .resource, .devicesEmpty: return false
        default: return true
        }
    }

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

/// Builds the final Resources section for one Cloud machine.
struct CloudTreeMachineResourceNodeBuilder {
    func groupNode(
        machine: SurfaceMachineID,
        snapshot: MachineSnapshot,
        now: Date
    ) -> CloudTreeNode {
        let section = CloudTreeMachineResourceSection(machine: snapshot, now: now)
        return CloudTreeNode(
            id: groupID(machine: machine),
            kind: .resourcesPool(machine: machine, count: section.rows.count),
            children: section.rows.map { row in
                CloudTreeNode(
                    id: rowID(machine: machine, metric: row.metric),
                    kind: .resource(machine: machine, row: row)
                )
            }
        )
    }

    func groupID(machine: SurfaceMachineID) -> String {
        "machine:\(machine.rawValue)/resources"
    }

    func rowID(machine: SurfaceMachineID, metric: CloudTreeMachineResourceMetric) -> String {
        "machine:\(machine.rawValue)/resources/\(metric.rawValue)"
    }

}
