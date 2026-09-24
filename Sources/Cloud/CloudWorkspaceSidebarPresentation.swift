import CmuxSidebar
import Foundation

/// Value-only Cloud provenance for both left-sidebar renderers and accessibility.
struct CloudWorkspaceSidebarPresentation {
    let machineLabel: String
    let directoryCandidates: [String]

    @MainActor
    static func deviceLabel(workspace: Workspace) -> String? {
        let state = workspace.cloudBindingState
        let machines = Set(state.projectedResources.values.map(\.machine).filter { $0.deviceInstance != nil })
        guard !machines.isEmpty else { return nil }
        let names = machines.sorted { $0.rawValue < $1.rawValue }.map { state.machineNames[$0.rawValue] ?? $0.rawValue }
        return String.localizedStringWithFormat(
            String(localized: "sidebar.deviceWorkspace.label", defaultValue: "Workspace on %@"), names.joined(separator: " · ")
        )
    }

    static var unavailableDirectory: String {
        String(localized: "sidebar.cloudWorkspace.directoryUnavailable", defaultValue: "Directory unavailable")
    }

    @MainActor
    init?(workspace: Workspace, orderedPanelIDs: [UUID], usesLastSegmentPath: Bool) {
        let state = workspace.cloudBindingState
        var machineIDs = Set(state.projectedResources.values.compactMap { $0.machine.cloudMachineID })
        if let id = workspace.cloudVMID { machineIDs.insert(id) }
        guard !machineIDs.isEmpty else { return nil }
        let names = Dictionary(uniqueKeysWithValues: machineIDs.map { id in
            let name = state.machineNames[id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? id
            return (id, name.isEmpty ? id : name)
        })
        // Keep stable IDs in badge help/accessibility; width-dependent rows use
        // them only when friendly names collide across machines.
        let identities = machineIDs.sorted().map { id -> String in
            let name = names[id] ?? id
            return name == id ? id : "\(name) (\(id))"
        }
        machineLabel = String.localizedStringWithFormat(
            String(localized: "sidebar.cloudWorkspace.label", defaultValue: "Cloud workspace on %@"),
            identities.joined(separator: " · ")
        )

        var entries: [(identity: String, directory: String?)] = []
        var seen = Set<String>()
        for panelID in orderedPanelIDs {
            guard let machineID = state.projectedResources[panelID]?.machine.cloudMachineID ?? workspace.cloudVMID else { continue }
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
