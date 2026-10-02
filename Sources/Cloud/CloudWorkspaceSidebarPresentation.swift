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
    private static func deviceMachines(for workspace: Workspace) -> Set<SurfaceMachineID> {
        var machines = Set(workspace.cloudBindingState.projectedResources.values.map(\.machine).filter(\.isDevice))
        machines.formUnion(SurfaceCatalog.shared.projectionMachines(forWorkspace: workspace.id).filter(\.isDevice))
        return machines
    }

    /// Formats a stable device-workspace label from live or restored machine identity.
    @MainActor
    private static func deviceLabel(workspace: Workspace, machines: Set<SurfaceMachineID>) -> String? {
        let state = workspace.cloudBindingState


        guard !machines.isEmpty else { return nil }
        let names = machines.sorted { $0.rawValue < $1.rawValue }.map {
            state.machineNames[$0.rawValue] ?? SurfaceCatalog.shared.machineInfo(for: $0)?.name ?? $0.rawValue
        }
        return String.localizedStringWithFormat(
            String(localized: "sidebar.deviceWorkspace.label", defaultValue: "Workspace on %@"), names.joined(separator: " · ")
        )
    }

    /// Returns the current device-workspace label for callers without a full presentation.
    @MainActor
    static func deviceLabel(workspace: Workspace) -> String? {
        deviceLabel(workspace: workspace, machines: deviceMachines(for: workspace))
    }

    static var unavailableDirectory: String {
        String(localized: "sidebar.cloudWorkspace.directoryUnavailable", defaultValue: "Directory unavailable")
    }

    @MainActor
    /// Builds the immutable remote sidebar identity and directory presentation.
    init?(workspace: Workspace, orderedPanelIDs: [UUID], usesLastSegmentPath: Bool) {
        let state = workspace.cloudBindingState

        func machineMetadata(for id: String) -> String? {
            if let name = state.machineNames[id] { return name }
            if let name = state.machineNames[SurfaceMachineID.cloud(id).rawValue] { return name }
            return SurfaceCatalog.shared.machineInfo(for: .cloud(id))?.name
        }

        var cloudMachineIDs = Set(state.projectedResources.values.compactMap { $0.machine.cloudMachineID })
        if let id = workspace.cloudVMID { cloudMachineIDs.insert(id) }
        let deviceMachines = Self.deviceMachines(for: workspace)
        let deviceMachineIDs = Set(deviceMachines.map(\.rawValue))
        isDeviceWorkspace = cloudMachineIDs.isEmpty && !deviceMachineIDs.isEmpty
        let machineIDs = cloudMachineIDs.union(deviceMachineIDs)

        guard !machineIDs.isEmpty else { return nil }
        deviceLabel = Self.deviceLabel(workspace: workspace, machines: deviceMachines)
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
        for panelID in orderedPanelIDs {
            let projectedMachine = state.projectedResources[panelID]?.machine
            guard let machineID = projectedMachine.flatMap({ $0.isDevice ? $0.rawValue : $0.cloudMachineID })
                ?? workspace.cloudVMID else { continue }
            let resource = state.projectedResources[panelID]
            guard resource?.kind == .terminal || workspace.terminalPanel(for: panelID) != nil else { continue }
            let directory = workspace.reportedPanelDirectory(panelId: panelID)
            guard seen.insert(machineID + "\n" + (directory ?? "")).inserted else { continue }
            entries.append((machineID, directory))
        }
        if entries.isEmpty { entries = machineIDs.sorted().map { ($0, nil) } }
        // Never expand or abbreviate a remote path using this Mac's home directory.
        let paths = entries.map { entry -> [String] in
            guard let directory = entry.directory else { return [Self.unavailableDirectory] }
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
