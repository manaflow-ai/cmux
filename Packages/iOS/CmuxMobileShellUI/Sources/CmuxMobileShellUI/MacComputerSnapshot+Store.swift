#if os(iOS)
import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileShell
import CmuxMobileShellModel
import Foundation

extension MacComputerSnapshot {
    /// The user's computers as immutable snapshots, sourced from the paired-Mac
    /// backup (`displayPairedMacs`) — the coalesced set the Computers screen
    /// shows and the one ``CMUXMobileShellStore/hideMac`` filters locally.
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
            let aliases = store.pairedMacAliasIDs(
                for: mac.macDeviceID,
                instanceTag: mac.instanceTag
            )
            let summary = store.presenceSummary(
                for: mac.macDeviceID,
                instanceTag: mac.instanceTag
            )
            let presence: DeviceTreePresence? = summary
                .map { $0.online ? .online : .offline(lastSeenAt: $0.lastSeenAt) }
            // Secondary state is pairing-keyed; the foreground/legacy entry
            // stays under the bare device key, refined to the exact pairing.
            let exactConnectionStatus = connectionStatuses[mac.id]
                ?? MobileShellComposite.exactPairingConnectionStatus(
                    deviceStatus: connectionStatuses[mac.macDeviceID],
                    connectedMacDeviceID: store.connectedMacDeviceID,
                    connectedMacInstanceTag: store.connectedMacInstanceTag,
                    rowMacDeviceID: mac.macDeviceID,
                    rowInstanceTag: mac.instanceTag
                )
            // The Computer's own method decides its section and which route's
            // endpoint the row leads with (generic fallback when the method
            // has no advertised route yet).
            let method = store.connectionMethod(for: mac)
            var snapshot = MacComputerSnapshot(
                deviceId: mac.macDeviceID,
                instanceTag: mac.instanceTag,
                title: buildScope?.computerDisplayName(mac.resolvedName) ?? mac.resolvedName,
                platform: "mac",
                colorIndex: colorIndex[mac.id]
                    ?? aliases.compactMap {
                        colorIndex[MobilePairedMac.pairingID(
                            macDeviceID: $0,
                            instanceTag: mac.instanceTag
                        )]
                    }.first,
                customColor: mac.customColor,
                customIcon: mac.customIcon,
                connectionStatus: exactConnectionStatus,
                presence: presence,
                buildLabel: summary?.buildLabel
                    ?? MacBuildChannel().label(bundleID: nil, tag: mac.instanceTag),
                routeDescription: method.routeKind.flatMap {
                    CmxAttachRoute.deviceTreeRouteDescription(for: mac.routes, kind: $0)
                } ?? CmxAttachRoute.deviceTreeRouteDescription(for: mac.routes),
                routes: mac.routes,
                lastSeenAt: mac.lastSeenAt,
                workspaceCount: store.workspaceCount(
                    for: mac.macDeviceID,
                    instanceTag: mac.instanceTag
                ),
                aliasIDs: aliases
            )
            snapshot.connectionMethod = method
            snapshot.routeKind = method.routeKind
            return snapshot
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
