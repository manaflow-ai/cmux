import CmuxSurfaceCatalogModel
import Foundation

/// Owns remote projections that were restored before their provider published a resource.
///
/// The panel id is the key because a local panel can have only one pending remote identity.
/// This prevents a late provider refresh from resurrecting an old resource or duplicating a
/// record that an autosave already captured.
struct SurfaceProjectionRestoreStore: Sendable {
    private var entriesByPanelID: [UUID: SurfaceProjection] = [:]
    private var capturedPanelIDs: Set<UUID> = []
    private var machineIDsByWorkspace: [UUID: Set<SurfaceMachineID>] = [:]
    private var machineCountsByWorkspace: [UUID: [SurfaceMachineID: Int]] = [:]

    var machineIDs: Set<SurfaceMachineID> {
        Set(entriesByPanelID.values.map(\.resource.machine))
    }

    var projections: [SurfaceProjection] {
        Array(entriesByPanelID.values)
    }

    /// Returns staged machine identity for one workspace without scanning other workspaces.
    func machineIDs(forWorkspace workspaceID: UUID) -> Set<SurfaceMachineID> {
        machineIDsByWorkspace[workspaceID] ?? []
    }

    /// Looks up a staged panel's identity without scanning other restored panels.
    func projection(forPanel panelID: UUID) -> SurfaceProjection? {
        entriesByPanelID[panelID]
    }

    func machineOwningPanel(_ panelID: UUID) -> SurfaceMachineID? {
        entriesByPanelID[panelID]?.resource.machine
    }

    /// Stages a remote projection until its provider publishes the resource.
    mutating func stage(_ record: SurfaceProjectionRecord, workspaceID: UUID) {
        if let previous = entriesByPanelID[record.panelID] {
            removeIndexedMachine(previous.resource.machine, from: previous.workspaceID)
        }
        let projection = SurfaceProjection(
            resource: record.resource,
            workspaceID: workspaceID,
            panelID: record.panelID,
            remoteWorkspaceID: record.remoteWorkspaceID,
            remoteTabID: record.remoteTabID
        )
        entriesByPanelID[record.panelID] = projection
        addIndexedMachine(record.resource.machine, to: workspaceID)
        capturedPanelIDs.remove(record.panelID)
    }

    /// Removes a staged projection for a panel and reports whether one existed.
    @discardableResult
    mutating func remove(panelID: UUID) -> Bool {
        guard let removed = entriesByPanelID.removeValue(forKey: panelID) else { return false }
        removeIndexedMachine(removed.resource.machine, from: removed.workspaceID)
        capturedPanelIDs.remove(panelID)
        return true
    }

    /// Removes all staged projections belonging to a machine.
    mutating func remove(machine: SurfaceMachineID) {
        let removed = entriesByPanelID.values.filter { $0.resource.machine == machine }
        for entry in removed { removeIndexedMachine(machine, from: entry.workspaceID) }
        entriesByPanelID = entriesByPanelID.filter { $0.value.resource.machine != machine }
        capturedPanelIDs = capturedPanelIDs.filter { entriesByPanelID[$0] != nil }
    }

    /// Moves a staged projection with its panel when the local workspace changes.
    @discardableResult
    mutating func move(panelID: UUID, to workspaceID: UUID) -> Bool {
        guard var entry = entriesByPanelID[panelID] else { return false }
        removeIndexedMachine(entry.resource.machine, from: entry.workspaceID)
        entry.workspaceID = workspaceID
        entriesByPanelID[panelID] = entry
        addIndexedMachine(entry.resource.machine, to: workspaceID)
        return true
    }

    /// Returns and removes staged projections whose resources are now available.
    mutating func takeResolvable(
        machine: SurfaceMachineID,
        availableResources: Set<SurfaceResourceID>,
        isAllowed: (SurfaceProjection) -> Bool = { _ in true }
    ) -> [SurfaceProjection] {
        let resolved = entriesByPanelID.values.filter {
            $0.resource.machine == machine && availableResources.contains($0.resource) && isAllowed($0)
        }
        for entry in resolved {
            entriesByPanelID[entry.panelID] = nil
            removeIndexedMachine(entry.resource.machine, from: entry.workspaceID)
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

    private mutating func addIndexedMachine(_ machine: SurfaceMachineID, to workspaceID: UUID) {
        machineCountsByWorkspace[workspaceID, default: [:]][machine, default: 0] += 1
        machineIDsByWorkspace[workspaceID, default: []].insert(machine)
    }

    private mutating func removeIndexedMachine(_ machine: SurfaceMachineID, from workspaceID: UUID) {
        guard var counts = machineCountsByWorkspace[workspaceID], let count = counts[machine] else { return }
        if count <= 1 {
            counts[machine] = nil
            machineIDsByWorkspace[workspaceID]?.remove(machine)
        } else {
            counts[machine] = count - 1
        }
        if counts.isEmpty {
            machineCountsByWorkspace[workspaceID] = nil
            machineIDsByWorkspace[workspaceID] = nil
        } else {
            machineCountsByWorkspace[workspaceID] = counts
        }
    }

    /// Returns staged records for capture and emits one breadcrumb per panel.
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

    /// Reconciles live records with staged records without duplicate panel identities.
    mutating func mergeRecords(into records: inout [SurfaceProjectionRecord], for workspaceID: UUID) {
        let pending = self.records(for: workspaceID)
        let pendingPanelIDs = Set(pending.map(\.panelID))
        records.removeAll { pendingPanelIDs.contains($0.panelID) }
        records.append(contentsOf: pending)
    }
}
