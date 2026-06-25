#if os(iOS)
import CMUXMobileCore
import CmuxMobileShell
import CmuxMobileShellModel
import Foundation

extension MacComputerSnapshot {
    static func stableSorted(_ computers: [MacComputerSnapshot]) -> [MacComputerSnapshot] {
        computers.sorted { lhs, rhs in
            let nameOrder = lhs.title.localizedStandardCompare(rhs.title)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return lhs.deviceId.localizedStandardCompare(rhs.deviceId) == .orderedAscending
        }
    }
}

extension CMUXMobileShellStore {
    var stableComputerSnapshots: [MacComputerSnapshot] {
        let workspaces = workspaces
        let workspaceCounts = Dictionary(
            grouping: workspaces.compactMap(\.macDeviceID),
            by: { $0 }
        ).mapValues(\.count)
        let colorIndex = machineColorIndex
        let connectionStatuses = macConnectionStatuses
        return MacComputerSnapshot.stableSorted(pairedMacs.map { mac in
            let summary = presenceMap.deviceSummary(deviceId: mac.macDeviceID)
            let presence: DeviceTreePresence? = summary
                .map { $0.online ? .online : .offline(lastSeenAt: $0.lastSeenAt) }
            return MacComputerSnapshot(
                deviceId: mac.macDeviceID,
                title: mac.resolvedName,
                platform: "mac",
                colorIndex: colorIndex[mac.macDeviceID],
                customColor: mac.customColor,
                customIcon: mac.customIcon,
                connectionStatus: connectionStatuses[mac.macDeviceID],
                presence: presence,
                buildLabel: summary?.buildLabel,
                routeDescription: CmxAttachRoute.deviceTreeRouteDescription(for: mac.routes),
                lastSeenAt: mac.lastSeenAt,
                workspaceCount: workspaceCounts[mac.macDeviceID] ?? 0
            )
        })
    }
}
#endif
