import CmuxCloud
import CmuxSurfaceCatalogModel
import Foundation

extension CloudTreeNode.Kind {
    /// Readings describe a machine without representing a selectable pane.
    var isSelectable: Bool {
        switch self {
        case .resource, .devicesEmpty, .machineDetailTabs, .machineEndSpacer: return false
        // Ports status rows (Discovering…, No reachable ports) are information
        // with their own button, not a row to select.
        case .placeholder(_, let placeholder) where placeholder.portStatus != nil: return false
        default: return true
        }
    }

    /// Port, resource, and terminal inventories start closed so their rows stay
    /// out of the summary; visible expanded machines still warm port discovery.
    /// Workspaces and Displays start closed too, so opening a machine shows a
    /// short summary first and each part opens on request.
    var isExpandedByDefault: Bool {
        switch self {
        case .portsGroup, .terminalsPool, .resourcesPool, .displaysPool:
            return false
        case .workspace(let machine, _, _, _, _):
            // Cloud machines open to a short summary; My Devices keep their
            // workspaces open as before.
            return machine.cloudMachineID == nil
        default:
            return true
        }
    }
}

/// Builds the final Resources section for one Cloud machine.
struct CloudTreeMachineResourceNodeBuilder {
    var section: (MachineSnapshot, Date) -> CloudTreeMachineResourceSection = {
        CloudTreeMachineResourceSection(machine: $0, now: $1)
    }
    func groupNode(
        machine: SurfaceMachineID,
        snapshot: MachineSnapshot,
        now: Date
    ) -> CloudTreeNode {
        let section = section(snapshot, now)
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
