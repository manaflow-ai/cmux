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
    static func snapshots(
        from store: CMUXMobileShellStore,
        instanceTag: String? = nil
    ) -> [MacComputerSnapshot] {
        let colorIndex = store.machineColorIndex
        // The iOS tag remains the display suffix/storage partition. Route and
        // presence identity comes from each authenticated paired Mac instead.
        let buildScope = MobileIOSBuildScope.current() ?? MobileIOSBuildScope(instanceTag)
        // The PHONE's own per-Mac connection (foreground or live secondary) — the
        // source of truth for the dot, distinct from presence.
        let connectionStatuses = store.macConnectionStatuses
        var snapshots = store.displayPairedMacs.map { mac in
            let presenceInstanceTag = instanceTag ?? mac.instanceTag
            let aliases = store.pairedMacAliasIDs(for: mac.macDeviceID)
            let summary = store.presenceSummary(
                for: mac.macDeviceID,
                instanceTag: presenceInstanceTag
            )
            let presence: DeviceTreePresence? = summary
                .map { $0.online ? .online : .offline(lastSeenAt: $0.lastSeenAt) }
            return MacComputerSnapshot(
                deviceId: mac.macDeviceID,
                title: buildScope?.computerDisplayName(mac.resolvedName) ?? mac.resolvedName,
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
        markOlderDuplicates(&snapshots)
        return snapshots
    }

    /// Flag rows that share a fresher row's name and are not online.
    ///
    /// A Mac that re-paired across dev builds before the shared device id
    /// (cmux PR https://github.com/manaflow-ai/cmux/pull/6772) left one stored
    /// record per old build UUID, all named after the same computer. They do
    /// not coalesce (each dials a different port), so without a marker the
    /// list reads as interchangeable duplicates. `displayPairedMacs` arrives
    /// last-seen-newest-first, so the first occurrence of a name is the live
    /// record and later non-online occurrences get labeled "Older pairing".
    /// An online row is never labeled: a running instance is not stale even
    /// if a fresher same-named record exists.
    private static func markOlderDuplicates(_ snapshots: inout [MacComputerSnapshot]) {
        var seenNames: Set<String> = []
        for index in snapshots.indices {
            let name = snapshots[index].title
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if seenNames.contains(name), snapshots[index].presence != .online {
                snapshots[index].isOlderDuplicate = true
            } else {
                seenNames.insert(name)
            }
        }
    }
}
#endif
