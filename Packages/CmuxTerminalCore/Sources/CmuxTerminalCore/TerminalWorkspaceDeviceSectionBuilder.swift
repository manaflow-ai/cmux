public import Foundation

/// Builds ``TerminalWorkspaceDeviceSection`` groupings from a flat workspace/host list.
public enum TerminalWorkspaceDeviceSectionBuilder {
    /// Groups workspaces by host, filtered by a query and sorted by recency.
    ///
    /// Workspaces whose host is unknown are dropped. When `query` is non-empty, only
    /// workspaces matching it (via ``TerminalWorkspace/matches(query:host:)``) are kept.
    /// Each section preserves first-seen host ordering after the recency sort.
    ///
    /// - Parameters:
    ///   - workspaces: The workspaces to group.
    ///   - hosts: The hosts the workspaces belong to.
    ///   - query: The search query to filter by (empty matches everything).
    /// - Returns: The non-empty device sections, in host order.
    public static func makeSections(
        workspaces: [TerminalWorkspace],
        hosts: [TerminalHost],
        query: String
    ) -> [TerminalWorkspaceDeviceSection] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        let hostsByID = Dictionary(uniqueKeysWithValues: hosts.map { ($0.id, $0) })
        let filtered = workspaces
            .filter { workspace in
                guard let host = hostsByID[workspace.hostID] else { return false }
                guard !normalizedQuery.isEmpty else { return true }
                return workspace.matches(query: normalizedQuery, host: host)
            }
            .sorted { $0.lastActivity > $1.lastActivity }

        var orderedHostIDs: [TerminalHost.ID] = []
        var grouped: [TerminalHost.ID: [TerminalWorkspace]] = [:]

        for workspace in filtered {
            if grouped[workspace.hostID] == nil {
                orderedHostIDs.append(workspace.hostID)
            }
            grouped[workspace.hostID, default: []].append(workspace)
        }

        return orderedHostIDs.compactMap { hostID in
            guard let host = hostsByID[hostID],
                  let workspaces = grouped[hostID],
                  !workspaces.isEmpty else {
                return nil
            }
            return TerminalWorkspaceDeviceSection(
                host: host,
                workspaces: workspaces
            )
        }
    }
}
