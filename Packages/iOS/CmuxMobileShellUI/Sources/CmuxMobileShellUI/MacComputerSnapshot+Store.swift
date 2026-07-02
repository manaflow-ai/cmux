#if os(iOS)
import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileShell
import CmuxMobileShellModel
import Foundation

extension MacComputerSnapshot {
    /// The user's computers as immutable snapshots, sourced from the paired-Mac
    /// backup (`displayPairedMacs`) — the coalesced set the Computers screen
    /// shows and the one ``CMUXMobileShellStore/forgetMac`` actually removes.
    /// Shared by the Computers screen and the disconnected reconnect list so
    /// both surfaces show the same deduplicated computers with the same
    /// presence, color, and customization data.
    @MainActor
    static func snapshots(from store: CMUXMobileShellStore) -> [MacComputerSnapshot] {
        let colorIndex = store.machineColorIndex
        // The PHONE's own per-Mac connection (foreground or live secondary) — the
        // source of truth for the dot, distinct from presence.
        let connectionStatuses = store.macConnectionStatuses
        return store.displayPairedMacs.map { mac in
            let aliases = store.pairedMacAliasIDs(for: mac.macDeviceID)
            let summary = store.presenceSummary(for: mac.macDeviceID)
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
                workspaceCount: store.workspaceCount(for: mac.macDeviceID),
                aliasIDs: aliases
            )
        }
    }
}
#endif
