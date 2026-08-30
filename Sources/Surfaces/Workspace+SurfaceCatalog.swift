import Foundation

/// The workspace's side of the surface catalog: the single seams through which a pane
/// joins, leaves, moves between, or changes inside a workspace tell the local provider.
extension Workspace {
    /// Called from `panelsWillChange(to:)` with the old set still in `panels`.
    func surfaceCatalogPanelsWillChange(to newValue: [UUID: any Panel]) {
        let provider = LocalSurfaceProvider.shared
        let old = panels
        for (panelID, panel) in newValue where old[panelID] == nil {
            provider.panelDidAppear(panel, in: self)
        }
        for panelID in old.keys where newValue[panelID] == nil {
            // A pane in flight to another workspace keeps its resource; the target's
            // `panelDidAppear` moves the projection.
            if surfaceTransferringPanelIds.contains(panelID) { continue }
            provider.panelWillDisappear(panelID: panelID)
        }
    }

    /// Titles and working directories are per-workspace dictionaries; forward the keys
    /// whose value changed so the local resource follows the tab bar.
    func surfaceCatalogPanelMetadataDidChange(old: [UUID: String], new: [UUID: String]) {
        guard old != new else { return }
        let provider = LocalSurfaceProvider.shared
        for panelID in Set(old.keys).union(new.keys) where old[panelID] != new[panelID] {
            provider.panelDidChange(panelID: panelID, in: self)
        }
    }

    /// Persisted projections for this workspace: remote resources only. Local panes are
    /// re-registered by the hooks when the restored pane is created.
    var surfaceProjectionRecordsForSession: [SurfaceProjectionRecord]? {
        let records = SurfaceCatalog.shared.projectionRecords(forWorkspace: id).filter { !$0.resource.machine.isLocal }
        return records.isEmpty ? nil : records
    }

    /// Re-links restored panes to the remote resources they projected, using the restore's
    /// old→new panel id map. The pane stays a placeholder shell until the resource's
    /// provider reports it and re-projects.
    func restoreSurfaceProjections(_ records: [SurfaceProjectionRecord]?, oldToNewPanelIds: [UUID: UUID]) {
        guard let records, !records.isEmpty else { return }
        let remapped = records.compactMap { record -> SurfaceProjectionRecord? in
            guard let newID = oldToNewPanelIds[record.panelID] ?? (panels[record.panelID] != nil ? record.panelID : nil) else { return nil }
            return SurfaceProjectionRecord(panelID: newID, resource: record.resource)
        }
        SurfaceCatalog.shared.restore(remapped, workspaceID: id)
    }
}
