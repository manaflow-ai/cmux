#if os(iOS)
import CMUXMobileCore
import CmuxMobileShell
import CmuxMobileShellModel
import Foundation

extension MacComputerSnapshot {
    static func stableSorted(_ computers: [MacComputerSnapshot]) -> [MacComputerSnapshot] {
        var firstIndexByID: [String: Int] = [:]
        var selectedByID: [String: MacComputerSnapshot] = [:]

        for (index, computer) in computers.enumerated() {
            firstIndexByID[computer.deviceId] = min(firstIndexByID[computer.deviceId] ?? index, index)
            guard let existing = selectedByID[computer.deviceId] else {
                selectedByID[computer.deviceId] = computer
                continue
            }
            if computer.sortsBeforeDuplicate(existing) {
                selectedByID[computer.deviceId] = computer.mergingPresentationMetadata(from: existing)
            } else {
                selectedByID[computer.deviceId] = existing.mergingPresentationMetadata(from: computer)
            }
        }

        let uniqueComputers = selectedByID
            .sorted { lhs, rhs in
                (firstIndexByID[lhs.key] ?? .max) < (firstIndexByID[rhs.key] ?? .max)
            }
            .map(\.value)

        return uniqueComputers.sorted { lhs, rhs in
            let connectionOrder = lhs.connectionSortRank < rhs.connectionSortRank
            if lhs.connectionSortRank != rhs.connectionSortRank { return connectionOrder }
            let nameOrder = lhs.title.localizedStandardCompare(rhs.title)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            let identityOrder = lhs.stableIdentity.localizedStandardCompare(rhs.stableIdentity)
            if identityOrder != .orderedSame { return identityOrder == .orderedAscending }
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

    private func sortsBeforeDuplicate(_ other: MacComputerSnapshot) -> Bool {
        if connectionSortRank != other.connectionSortRank {
            return connectionSortRank < other.connectionSortRank
        }
        if lastSeenAt != other.lastSeenAt {
            return lastSeenAt > other.lastSeenAt
        }
        if workspaceCount != other.workspaceCount {
            return workspaceCount > other.workspaceCount
        }
        return title.localizedStandardCompare(other.title) == .orderedAscending
    }

    private func mergingPresentationMetadata(from other: MacComputerSnapshot) -> MacComputerSnapshot {
        var seenAliases: Set<String> = []
        return MacComputerSnapshot(
            deviceId: deviceId,
            title: title,
            platform: platform,
            colorIndex: colorIndex ?? other.colorIndex,
            customColor: customColor ?? other.customColor,
            customIcon: customIcon ?? other.customIcon,
            connectionStatus: connectionStatus,
            presence: presence ?? other.presence,
            buildLabel: buildLabel ?? other.buildLabel,
            routeDescription: routeDescription ?? other.routeDescription,
            lastSeenAt: lastSeenAt,
            workspaceCount: max(workspaceCount, other.workspaceCount),
            aliasIDs: (aliasIDs + other.aliasIDs).filter { seenAliases.insert($0).inserted }
        )
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
