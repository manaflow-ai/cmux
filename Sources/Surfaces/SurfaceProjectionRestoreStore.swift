import Foundation

/// Owns remote projections that were restored before their provider published a resource.
///
/// The panel id is the key because a local panel can have only one pending remote identity.
/// This prevents a late provider refresh from resurrecting an old resource or duplicating a
/// record that an autosave already captured.
struct SurfaceProjectionRestoreStore: Sendable {
    private var entriesByPanelID: [UUID: SurfaceProjection] = [:]
    private var capturedPanelIDs: Set<UUID> = []

    var machineIDs: Set<SurfaceMachineID> {
        Set(entriesByPanelID.values.map(\.resource.machine))
    }

    mutating func stage(_ record: SurfaceProjectionRecord, workspaceID: UUID) {
        entriesByPanelID[record.panelID] = SurfaceProjection(
            resource: record.resource,
            workspaceID: workspaceID,
            panelID: record.panelID,
            remoteWorkspaceID: record.remoteWorkspaceID,
            remoteTabID: record.remoteTabID
        )
        capturedPanelIDs.remove(record.panelID)
    }

    mutating func remove(panelID: UUID) {
        entriesByPanelID[panelID] = nil
        capturedPanelIDs.remove(panelID)
    }

    func contains(panelID: UUID) -> Bool { entriesByPanelID[panelID] != nil }

    mutating func remove(machine: SurfaceMachineID) {
        entriesByPanelID = entriesByPanelID.filter { $0.value.resource.machine != machine }
        capturedPanelIDs = capturedPanelIDs.filter { entriesByPanelID[$0] != nil }
    }

    @discardableResult
    mutating func move(panelID: UUID, to workspaceID: UUID) -> Bool {
        guard var entry = entriesByPanelID[panelID] else { return false }
        entry.workspaceID = workspaceID
        entriesByPanelID[panelID] = entry
        return true
    }

    mutating func takeResolvable(
        machine: SurfaceMachineID,
        availableResources: Set<SurfaceResourceID>
    ) -> [SurfaceProjection] {
        let resolved = entriesByPanelID.values.filter {
            $0.resource.machine == machine && availableResources.contains($0.resource)
        }
        for entry in resolved {
            entriesByPanelID[entry.panelID] = nil
            capturedPanelIDs.remove(entry.panelID)
            StartupBreadcrumbLog.append(
                "session.restore.projection.assigned",
                fields: [
                    "workspace": entry.workspaceID.uuidString,
                    "panel": entry.panelID.uuidString,
                    "machine": machine.rawValue,
                    "resource": entry.resource.key,
                    "tab": entry.remoteTabID ?? "none"
                ]
            )
        }
        return resolved
    }

    mutating func records(for workspaceID: UUID) -> [SurfaceProjectionRecord] {
        let pending = entriesByPanelID.values.filter { $0.workspaceID == workspaceID }
        for entry in pending where capturedPanelIDs.insert(entry.panelID).inserted {
            StartupBreadcrumbLog.append(
                "session.restore.projection.captured",
                fields: [
                    "workspace": workspaceID.uuidString,
                    "panel": entry.panelID.uuidString,
                    "machine": entry.resource.machine.rawValue,
                    "resource": entry.resource.key,
                    "tab": entry.remoteTabID ?? "none"
                ]
            )
        }
        return pending
            .filter { $0.workspaceID == workspaceID }
            .map {
                SurfaceProjectionRecord(
                    panelID: $0.panelID,
                    resource: $0.resource,
                    remoteWorkspaceID: $0.remoteWorkspaceID,
                    remoteTabID: $0.remoteTabID
                )
            }
    }
}
