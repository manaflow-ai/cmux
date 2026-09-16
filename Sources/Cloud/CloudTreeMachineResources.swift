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

    /// Removes cached live readings when the machine link is not authoritative.
    func snapshot(
        from machine: MachineSnapshot,
        linkState: SurfaceLinkState?,
        now: Date
    ) -> MachineSnapshot {
        var snapshot = machine
        switch linkState {
        case .some(.connected), .some(.notApplicable):
            break
        case .some(.asleep):
            let previous = machine.stats
            snapshot.stats = VMStats(
                state: .asleep,
                sampledAt: now,
                cpus: previous?.cpus,
                cpuPercent: nil,
                loadAverage1m: nil,
                memoryTotalMb: previous?.memoryTotalMb,
                memoryUsedMb: nil,
                diskTotalMb: previous?.diskTotalMb,
                diskUsedMb: nil
            )
        case .some(.connecting), .some(.error), .some(.unavailable), .none:
            snapshot.capabilities.stats = false
            snapshot.stats = nil
        }
        return snapshot
    }
}
