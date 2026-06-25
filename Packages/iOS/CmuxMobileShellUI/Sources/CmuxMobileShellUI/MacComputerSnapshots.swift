#if os(iOS)
import CMUXMobileCore
import CmuxMobileShell
import CmuxMobileShellModel
import Foundation

extension MacComputerSnapshot {
    static func stableSorted(_ computers: [MacComputerSnapshot]) -> [MacComputerSnapshot] {
        computers.sorted { lhs, rhs in
            let connectionOrder = lhs.connectionSortRank < rhs.connectionSortRank
            if lhs.connectionSortRank != rhs.connectionSortRank { return connectionOrder }
            let nameOrder = lhs.title.localizedStandardCompare(rhs.title)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return lhs.deviceId.localizedStandardCompare(rhs.deviceId) == .orderedAscending
        }
    }

    private var connectionSortRank: Int {
        switch connectionStatus {
        case .connected:
            return 0
        case .reconnecting:
            return 1
        case .unavailable, nil:
            return 2
        }
    }
}

extension CMUXMobileShellStore {
    var stableComputerSnapshots: [MacComputerSnapshot] {
        let workspaceCounts = Dictionary(
            grouping: workspaces.compactMap(\.macDeviceID),
            by: { $0 }
        ).mapValues(\.count)
        let colorIndex = machineColorIndex
        let connectionStatuses = macConnectionStatuses
        return MacComputerSnapshot.stableSorted(displayPairedMacs.map { mac in
            let aliases = pairedMacAliasIDs(for: mac.macDeviceID)
            let summaries = aliases.compactMap { presenceMap.deviceSummary(deviceId: $0) }
            let freshest = summaries.max { $0.lastSeenAt < $1.lastSeenAt }
            let summary = summaries.isEmpty ? nil : PresenceMap.DeviceSummary(
                online: summaries.contains(where: \.online),
                lastSeenAt: freshest?.lastSeenAt ?? Date(timeIntervalSince1970: 0),
                buildLabel: summaries.first { $0.online && $0.buildLabel != nil }?.buildLabel
                    ?? freshest?.buildLabel
            )
            let presence: DeviceTreePresence? = summary
                .map { $0.online ? .online : .offline(lastSeenAt: $0.lastSeenAt) }
            return MacComputerSnapshot(
                deviceId: mac.macDeviceID,
                title: mac.resolvedName,
                platform: "mac",
                colorIndex: aliases.compactMap { colorIndex[$0] }.first,
                customColor: mac.customColor,
                customIcon: mac.customIcon,
                connectionStatus: connectionStatuses[mac.macDeviceID],
                presence: presence,
                buildLabel: summary?.buildLabel,
                routeDescription: CmxAttachRoute.deviceTreeRouteDescription(for: mac.routes),
                lastSeenAt: mac.lastSeenAt,
                workspaceCount: aliases.reduce(0) { total, macDeviceID in
                    total + (workspaceCounts[macDeviceID] ?? 0)
                },
                aliasIDs: aliases
            )
        })
    }
}
#endif
