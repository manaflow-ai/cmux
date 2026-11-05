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
    private var panelIDsByWorkspace: [UUID: Set<UUID>] = [:]
    private var uncapturedPanelIDsByWorkspace: [UUID: Set<UUID>] = [:]

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
            removeFromIndexes(previous)
        }
        let projection = SurfaceProjection(
            resource: record.resource,
            workspaceID: workspaceID,
            panelID: record.panelID,
            remoteWorkspaceID: record.remoteWorkspaceID,
            remoteTabID: record.remoteTabID
        )
        entriesByPanelID[record.panelID] = projection
        capturedPanelIDs.remove(record.panelID)
        addToIndexes(projection)
    }

    /// Removes a staged projection for a panel and reports whether one existed.
    @discardableResult
    mutating func remove(panelID: UUID) -> Bool {
        guard let removed = entriesByPanelID.removeValue(forKey: panelID) else { return false }
        removeFromIndexes(removed)
        capturedPanelIDs.remove(panelID)
        return true
    }

    /// Removes all staged projections belonging to a machine.
    mutating func remove(machine: SurfaceMachineID) {
        let removed = entriesByPanelID.values.filter { $0.resource.machine == machine }
        for entry in removed { removeFromIndexes(entry) }
        entriesByPanelID = entriesByPanelID.filter { $0.value.resource.machine != machine }
        capturedPanelIDs = capturedPanelIDs.filter { entriesByPanelID[$0] != nil }
    }

    /// Moves a staged projection with its panel when the local workspace changes.
    @discardableResult
    mutating func move(panelID: UUID, to workspaceID: UUID) -> Bool {
        guard var entry = entriesByPanelID[panelID] else { return false }
        removeFromIndexes(entry)
        entry.workspaceID = workspaceID
        entriesByPanelID[panelID] = entry
        addToIndexes(entry)
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
            removeFromIndexes(entry)
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

    private mutating func addToIndexes(_ entry: SurfaceProjection) {
        addIndexedMachine(entry.resource.machine, to: entry.workspaceID)
        panelIDsByWorkspace[entry.workspaceID, default: []].insert(entry.panelID)
        if !capturedPanelIDs.contains(entry.panelID) {
            uncapturedPanelIDsByWorkspace[entry.workspaceID, default: []].insert(entry.panelID)
        }
    }

    private mutating func removeFromIndexes(_ entry: SurfaceProjection) {
        removeIndexedMachine(entry.resource.machine, from: entry.workspaceID)
        Self.remove(entry.panelID, from: entry.workspaceID, in: &panelIDsByWorkspace)
        Self.remove(entry.panelID, from: entry.workspaceID, in: &uncapturedPanelIDsByWorkspace)
    }

    private static func remove(_ panelID: UUID, from workspaceID: UUID, in index: inout [UUID: Set<UUID>]) {
        index[workspaceID]?.remove(panelID)
        if index[workspaceID]?.isEmpty == true { index[workspaceID] = nil }
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

    /// Whether a staged record for `workspaceID` has not been captured yet.
    func hasUncapturedRecords(for workspaceID: UUID) -> Bool {
        uncapturedPanelIDsByWorkspace[workspaceID] != nil
    }

    /// Emits one breadcrumb per staged panel of `workspaceID` the first time it is captured.
    mutating func markRecordsCaptured(for workspaceID: UUID) {
        guard let pending = uncapturedPanelIDsByWorkspace.removeValue(forKey: workspaceID) else { return }
        for entry in pending.compactMap({ entriesByPanelID[$0] }) {
            capturedPanelIDs.insert(entry.panelID)
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
    }

    /// Staged records for capture. Read-only, so an observed owner can call it
    /// while snapshotting without publishing a change.
    func records(for workspaceID: UUID) -> [SurfaceProjectionRecord] {
        (panelIDsByWorkspace[workspaceID] ?? [])
            .compactMap { entriesByPanelID[$0] }
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
    func mergeRecords(into records: inout [SurfaceProjectionRecord], for workspaceID: UUID) {
        let pending = self.records(for: workspaceID)
        let pendingPanelIDs = Set(pending.map(\.panelID))
        records.removeAll { pendingPanelIDs.contains($0.panelID) }
        records.append(contentsOf: pending)
    }
}
