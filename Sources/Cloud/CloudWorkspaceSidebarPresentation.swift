import CmuxSidebar
import Foundation

/// Value-only Cloud provenance for both left-sidebar renderers and accessibility.
struct CloudWorkspaceSidebarPresentation {
    let machineLabel: String
    let directoryCandidates: [String]

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
        // Keep stable IDs in badge help/accessibility, not in width-dependent row text.
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
        let full = zip(entries, paths).map { entry, paths -> String in
            "\(names[entry.identity] ?? entry.identity) · \(paths.first ?? Self.unavailableDirectory)"
        }.joined(separator: " | ")
        let compact = zip(entries, paths).map { "\(names[$0.identity] ?? $0.identity) · \($1.last ?? Self.unavailableDirectory)" }.joined(separator: " | ")
        directoryCandidates = full == compact ? [full] : [full, compact]
    }
}
