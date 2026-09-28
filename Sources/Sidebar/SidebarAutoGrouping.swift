import Foundation

/// Computes the sections an automatic Group By mode draws.
///
/// Pure: it reads only the inputs it is given. Sections keep each workspace in
/// the order the inputs arrive (the window's `tabs` order), and empty sections
/// are never produced. Manual mode has no derived sections.
struct SidebarAutoGrouping {
    let mode: SidebarGroupByMode

    /// The section key a workspace belongs to, or nil in manual mode. The
    /// sidebar's liveness observer compares these to detect a regroup.
    func sectionKey(for input: SidebarAutoGroupingInput) -> String? {
        switch mode {
        case .manual: return nil
        case .host: return input.host.sectionKey
        case .status: return input.status.sectionKey
        }
    }

    func sections(for inputs: [SidebarAutoGroupingInput]) -> [SidebarAutoGroupingSection] {
        switch mode {
        case .manual:
            return []
        case .host:
            return hostSections(for: inputs)
        case .status:
            return statusSections(for: inputs)
        }
    }

    private func statusSections(for inputs: [SidebarAutoGroupingInput]) -> [SidebarAutoGroupingSection] {
        var idsByStatus: [SidebarAutoGroupingStatus: [UUID]] = [:]
        for input in inputs {
            idsByStatus[input.status, default: []].append(input.workspaceId)
        }
        return SidebarAutoGroupingStatus.allCases.compactMap { status in
            guard let ids = idsByStatus[status], !ids.isEmpty else { return nil }
            return SidebarAutoGroupingSection(
                key: status.sectionKey,
                title: status.localizedTitle,
                symbol: status.symbol,
                workspaceIds: ids
            )
        }
    }

    /// This Mac first, then SSH hosts by name, then Cloud VMs by name.
    private func hostSections(for inputs: [SidebarAutoGroupingInput]) -> [SidebarAutoGroupingSection] {
        var localIds: [UUID] = []
        var buckets: [String: (title: String, symbol: String, isCloud: Bool, ids: [UUID])] = [:]
        for input in inputs {
            let key = input.host.sectionKey
            switch input.host {
            case .local:
                localIds.append(input.workspaceId)
                continue
            case .remote(let target):
                if buckets[key] == nil {
                    buckets[key] = (SidebarAutoGroupingHost.hostName(fromTarget: target), "network", false, [])
                }
            case .cloud(_, let label):
                if buckets[key] == nil {
                    let title = label ?? String(localized: "sidebar.groupBy.section.cloudVM", defaultValue: "Cloud VM")
                    buckets[key] = (title, "cloud", true, [])
                }
            }
            buckets[key]?.ids.append(input.workspaceId)
        }
        var sections: [SidebarAutoGroupingSection] = []
        if !localIds.isEmpty {
            sections.append(SidebarAutoGroupingSection(
                key: SidebarAutoGroupingHost.local.sectionKey,
                title: String(localized: "sidebar.groupBy.section.thisMac", defaultValue: "This Mac"),
                symbol: "laptopcomputer",
                workspaceIds: localIds
            ))
        }
        // SSH hosts before Cloud VMs; case-insensitive title order inside each,
        // with the key as a tiebreak so equal titles never swap between renders.
        let ordered = buckets.sorted { lhs, rhs in
            if lhs.value.isCloud != rhs.value.isCloud { return !lhs.value.isCloud }
            switch lhs.value.title.localizedCaseInsensitiveCompare(rhs.value.title) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return lhs.key < rhs.key
            }
        }
        sections.append(contentsOf: ordered.map { key, bucket in
            SidebarAutoGroupingSection(key: key, title: bucket.title, symbol: bucket.symbol, workspaceIds: bucket.ids)
        })
        return sections
    }
}
