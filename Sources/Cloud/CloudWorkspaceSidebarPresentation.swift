import CmuxSidebar
import CmuxSurfaceCatalogModel
import Foundation

/// Value-only remote provenance for both left-sidebar renderers and accessibility.
struct CloudWorkspaceSidebarPresentation {
    let machineLabel: String
    let directoryCandidates: [String]
    let isDeviceWorkspace: Bool
    let deviceLabel: String?

    /// Returns durable device provenance without scanning the catalog's projection set.
    @MainActor
    private static func deviceMachines(for workspace: Workspace, catalog: SurfaceCatalog) -> Set<SurfaceMachineID> {
        var machines = Set(workspace.cloudBindingState.projectedResources.values.map(\.machine).filter(\.isDevice))
        machines.formUnion(catalog.projectionMachines(forWorkspace: workspace.id).filter(\.isDevice))
        return machines
    }

    /// Formats a stable device-workspace label from live or restored machine identity.
    @MainActor
    private static func deviceLabel(workspace: Workspace, machines: Set<SurfaceMachineID>, catalog: SurfaceCatalog) -> String? {
        let state = workspace.cloudBindingState


        guard !machines.isEmpty else { return nil }
        let names = machines.sorted { $0.rawValue < $1.rawValue }.map {
            state.machineNames[$0.rawValue] ?? catalog.machineInfo(for: $0)?.name ?? $0.rawValue
        }
        return String.localizedStringWithFormat(
            String(localized: "sidebar.deviceWorkspace.label", defaultValue: "Workspace on %@"), names.joined(separator: " · ")
        )
    }

    /// Returns the current device-workspace label for callers without a full presentation.
    @MainActor
    static func deviceLabel(workspace: Workspace, catalog: SurfaceCatalog = .shared) -> String? {
        deviceLabel(workspace: workspace, machines: deviceMachines(for: workspace, catalog: catalog), catalog: catalog)
    }

    static var unavailableDirectory: String {
        String(localized: "sidebar.cloudWorkspace.directoryUnavailable", defaultValue: "Directory unavailable")
    }

    @MainActor
    /// Builds the immutable remote sidebar identity and directory presentation.
    init?(workspace: Workspace, orderedPanelIDs: [UUID], usesLastSegmentPath: Bool, catalog: SurfaceCatalog = .shared) {
        let state = workspace.cloudBindingState

        func machineMetadata(for id: String) -> String? {
            if let name = state.machineNames[id] { return name }
            if let name = state.machineNames[SurfaceMachineID.cloud(id).rawValue] { return name }
            return catalog.machineInfo(for: .cloud(id))?.name
        }

        var cloudMachineIDs = Set(state.projectedResources.values.compactMap { $0.machine.cloudMachineID })
        if let id = workspace.cloudVMID { cloudMachineIDs.insert(id) }
        let deviceMachines = Self.deviceMachines(for: workspace, catalog: catalog)
        let deviceMachineIDs = Set(deviceMachines.map(\.rawValue))
        isDeviceWorkspace = cloudMachineIDs.isEmpty && !deviceMachineIDs.isEmpty
        let machineIDs = cloudMachineIDs.union(deviceMachineIDs)

        guard !machineIDs.isEmpty else { return nil }
        deviceLabel = Self.deviceLabel(workspace: workspace, machines: deviceMachines, catalog: catalog)
        let names = Dictionary(uniqueKeysWithValues: machineIDs.map { id in
            let name = machineMetadata(for: id)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? id
            return (id, name.isEmpty ? id : name)
        })
        // A restored Cloud terminal can publish its projection before the
        // catalog has finished loading machine metadata. Do not turn that
        // transient state into user-visible identity or directory copy: the
        // raw VM id and "Directory unavailable" are loading placeholders, not
        // the values the sidebar is meant to present.
        let projectedCloudMachineIDs = Set(state.projectedResources.values.compactMap { resource in
            resource.machine.cloudMachineID
        })
        guard projectedCloudMachineIDs.allSatisfy({ id in
            guard machineMetadata(for: id) != nil else { return false }
            return true
        }) else { return nil }
        // Keep stable IDs in badge help/accessibility; width-dependent rows use
        // them only when friendly names collide across machines.
        let identities = machineIDs.sorted().map { id -> String in
            let name = names[id] ?? id
            return name == id ? id : "\(name) (\(id))"
        }
        machineLabel = String.localizedStringWithFormat(
            isDeviceWorkspace
                ? String(localized: "sidebar.deviceWorkspace.label", defaultValue: "Workspace on %@")
                : String(localized: "sidebar.cloudWorkspace.label", defaultValue: "Cloud workspace on %@"),
            identities.joined(separator: " · ")
        )

        var entries: [(identity: String, directory: String?)] = []
        var seen = Set<String>()
        let catalogSnapshot = catalog.snapshot
        func acceptedMachineDirectory(for machineID: String) -> String? {
            let machine = SurfaceMachineID(rawValue: machineID)
            let resources = catalogSnapshot.resources(on: machine).filter { $0.kind == .terminal }
            let workspaceDirectory = resources
                .flatMap { resource in
                    resource.remoteWorkspaces
                        .filter { $0.id == (workspace.cloudVMBinding?.remoteWorkspaceID ?? "") }
                        .compactMap(\.detail)
                }
                .first(where: { !$0.isEmpty })
            return workspaceDirectory ?? resources
                .compactMap(\.detail)
                .first(where: { !$0.isEmpty })
        }
        for panelID in orderedPanelIDs {
            let projectedMachine = state.projectedResources[panelID]?.machine
            guard let machineID = projectedMachine.flatMap({ $0.isDevice ? $0.rawValue : $0.cloudMachineID })
                ?? workspace.cloudVMID else { continue }
            let resourceID = state.projectedResources[panelID]
            if let resourceID {
                // A restored workspace can retain a panel projection after the
                // provider has published a current graph without that resource.
                // Do not turn that stale identity into a directory placeholder.
                guard let resource = catalog.resources[resourceID], resource.kind == .terminal else {
                    continue
                }
                if resource.lifecycle == .launching {
                    continue
                }
            } else {
                guard workspace.terminalPanel(for: panelID) != nil else { continue }
            }
            let directory = workspace.reportedPanelDirectory(panelId: panelID)
                ?? acceptedMachineDirectory(for: machineID)
            // Missing provider data is a normal loading state. Never turn it
            // into an error-looking directory label in the workspace row.
            guard let directory else { continue }
            guard seen.insert(machineID + "\n" + directory).inserted else { continue }
            entries.append((machineID, directory))
        }

        guard !entries.isEmpty else {
            directoryCandidates = []
            return
        }
        // Never expand or abbreviate a remote path using this Mac's home directory.
        let paths = entries.map { entry -> [String] in
            guard let directory = entry.directory else { return [] }
            return usesLastSegmentPath
                ? SidebarPathFormatter.pathCandidates(directory, homeDirectoryPath: "")
                : [directory]
        }
        var grouped: [(identity: String, paths: [[String]])] = []
        var groupIndexes: [String: Int] = [:]
        for (entry, pathCandidates) in zip(entries, paths) {
            if let index = groupIndexes[entry.identity] {
                grouped[index].paths.append(pathCandidates)
            } else {
                groupIndexes[entry.identity] = grouped.count
                grouped.append((entry.identity, [pathCandidates]))
            }
        }
        var nameCounts: [String: Int] = [:]
        for group in grouped {
            nameCounts[names[group.identity, default: group.identity], default: 0] += 1
        }
        let visibleName: (String) -> String = { id in
            let name = names[id] ?? id
            guard name != id, nameCounts[name, default: 0] > 1 else { return name }
            return "\(name) (\(id))"
        }
        let full = grouped.map { group in
            "\(visibleName(group.identity)) · " + group.paths.map { $0.first ?? Self.unavailableDirectory }.joined(separator: ", ")
        }.joined(separator: " | ")
        let compact = grouped.map { group in
            "\(visibleName(group.identity)) · " + group.paths.map { $0.last ?? Self.unavailableDirectory }.joined(separator: ", ")
        }.joined(separator: " | ")
        directoryCandidates = full == compact ? [full] : [full, compact]
    }
}
