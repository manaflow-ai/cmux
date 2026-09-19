import Foundation

extension SurfaceCatalog {
    /// The unmodified provider rows, used to enumerate destructive operations.
    var authoritativeSnapshot: SurfaceCatalogSnapshot {
        SurfaceCatalogSnapshot(
            machines: machines.values.sorted {
                if $0.id.isLocal != $1.id.isLocal { return $0.id.isLocal }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            },
            resources: resources.values.sorted { $0.catalogPrecedes($1) },
            projections: projections.sorted { $0.panelID.uuidString < $1.panelID.uuidString }
        )
    }

    /// Projects deletion and rename intents over provider state for all
    /// sidebar/CLI readers, so every entrypoint sees one optimistic tree.
    var snapshot: SurfaceCatalogSnapshot {
        var result = authoritativeSnapshot
        applyPendingDeletions(to: &result)
        applyPendingRenames(to: &result)
        return result
    }

    /// Hides workspaces admitted for deletion. Shared browser/display resources
    /// keep their other placements. Terminals are killed resource-wide by the
    /// established full-delete contract.
    private func applyPendingDeletions(to result: inout SurfaceCatalogSnapshot) {
        let entries = cloudWorkspaceDeletionLedger.entries
        guard !entries.isEmpty else { return }
        func hidden(_ machine: SurfaceMachineID, _ workspace: String) -> Bool {
            entries[.init(machine: machine, workspaceID: workspace)] != nil
        }
        let terminalIDs = entries.values.reduce(into: Set<SurfaceResourceID>()) { $0.formUnion($1.terminalIDs) }
        result.machines = result.machines.map { info in
            var info = info
            info.remoteWorkspaces = info.remoteWorkspaces?.filter { !hidden(info.id, $0.id) }
            return info
        }
        let originalResourceIDs = Set(result.resources.map(\.id))
        result.resources = result.resources.compactMap { resource in
            if terminalIDs.contains(resource.id) { return nil }
            let affected = resource.remoteWorkspaces.contains { hidden(resource.machine, $0.id) }
            guard affected else { return resource }
            if resource.kind == .terminal { return nil }
            var resource = resource
            if let views = resource.remoteViews {
                resource.remoteViews = views.filter { !hidden(resource.machine, $0.workspace.id) }
                resource.remoteWorkspace = resource.remoteViews?.first?.workspace
                if resource.remoteViews?.isEmpty == true { return nil }
            } else { return nil }
            return resource
        }
        let hiddenIDs = originalResourceIDs.subtracting(result.resources.map(\.id)).union(terminalIDs)
        result.projections.removeAll { projection in
            hiddenIDs.contains(projection.resource)
                || projection.remoteWorkspaceID.map { hidden(projection.resource.machine, $0) } == true
        }
        result.pendingWorkspaceDeletions = cloudWorkspaceDeletionLedger.pending
    }

    /// Names the person already chose, ahead of the daemon's accepted graph. The
    /// coordinator holds an intent until its RPC returns; the machine's
    /// observation holds an accepted receipt until the graph passes it. A failed
    /// intent drops out of both, so the row falls back to the authoritative name.
    var pendingCloudRenames: [CloudRenameCoordinator.Key: String] {
        var names = cloudRenameCoordinator.allPendingNames
        for (machine, observation) in cloudStateObservations {
            for write in observation.pendingWrites ?? [] {
                let key: CloudRenameCoordinator.Key
                switch write.kind {
                case .workspaceRename:
                    guard let id = write.remoteWorkspaceID else { continue }
                    key = .workspace(machine: machine, id: id)
                case .tabRename:
                    guard let id = write.remoteTabID else { continue }
                    key = .tab(machine: machine, id: id)
                case .terminalCreate:
                    continue
                }
                if names[key] == nil, let name = write.name { names[key] = name }
            }
        }
        return names
    }

    /// Stamps pending names onto every place a row reads a name from: the
    /// machine's workspace list, each resource's workspace, and each tab view.
    /// An exact tab intent wins over a terminal-wide ("all views") intent; an
    /// empty tab name clears the custom label, as the daemon will.
    private func applyPendingRenames(to result: inout SurfaceCatalogSnapshot) {
        let names = pendingCloudRenames
        guard !names.isEmpty else { return }
        func renamed(_ workspace: SurfaceRemoteWorkspace, on machine: SurfaceMachineID) -> SurfaceRemoteWorkspace {
            guard let name = names[.workspace(machine: machine, id: workspace.id)] else { return workspace }
            var workspace = workspace
            workspace.name = name
            return workspace
        }
        result.machines = result.machines.map { info in
            guard let workspaces = info.remoteWorkspaces else { return info }
            var info = info
            info.remoteWorkspaces = workspaces.map { renamed($0, on: info.id) }
            return info
        }
        result.resources = result.resources.map { resource in
            var resource = resource
            let machine = resource.machine
            if let workspace = resource.remoteWorkspace { resource.remoteWorkspace = renamed(workspace, on: machine) }
            if let views = resource.remoteViews {
                resource.remoteViews = views.map { view in
                    var view = view
                    view.workspace = renamed(view.workspace, on: machine)
                    if let name = names[.tab(machine: machine, id: view.tabID)]
                        ?? names[.terminal(machine: machine, id: resource.id.key)] {
                        view.name = name.isEmpty ? nil : name
                    }
                    return view
                }
            }
            return resource
        }
    }
}
