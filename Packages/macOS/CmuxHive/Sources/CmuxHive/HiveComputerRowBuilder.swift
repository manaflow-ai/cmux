import CMUXMobileCore
public import CmuxMobilePairedMac
public import CmuxMobileShell
public import CmuxMobileShellModel
import Foundation

/// Builds one immutable computer-row snapshot from registry, pairing, and
/// live-presence values.
///
/// The directory owns lifecycle and caching; this value type owns only the
/// merge policy so incremental presence updates can rebuild affected rows
/// without rescanning unrelated devices.
public nonisolated struct HiveComputerRowBuilder: Sendable {
    /// The local device id used to mark the This Mac row.
    public let ownDeviceID: String

    /// Creates a row builder for one local device.
    public init(ownDeviceID: String) {
        self.ownDeviceID = ownDeviceID
    }

    /// Builds all rows from the current source snapshots.
    public func makeRows(
        registry: [RegistryDevice],
        paired: [MobilePairedMac],
        presence: PresenceMap
    ) -> [HiveComputer] {
        let pairedByID = indexPairedRecords(paired)
        let pairedRecordsByID = Dictionary(grouping: paired, by: \.macDeviceID)
        let registryByID = Dictionary(
            registry.map { ($0.deviceId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let ids = Set(registryByID.keys).union(pairedByID.keys)
        return ids.compactMap { id in
            makeRow(
                registry: registryByID[id],
                paired: pairedByID[id],
                pairedRecords: pairedRecordsByID[id] ?? [],
                presence: presence
            )
        }
        .sorted(by: comesBefore)
    }

    /// Index paired records without trapping when tagged instances share a
    /// physical device id; prefer the active, then freshest, record.
    func indexPairedRecords(_ records: [MobilePairedMac]) -> [String: MobilePairedMac] {
        records.reduce(into: [String: MobilePairedMac]()) { result, record in
            guard let existing = result[record.macDeviceID] else {
                result[record.macDeviceID] = record
                return
            }
            let preferRecord = (record.isActive && !existing.isActive)
                || (record.isActive == existing.isActive && record.lastSeenAt > existing.lastSeenAt)
            if preferRecord {
                result[record.macDeviceID] = record
            }
        }
    }

    /// Builds a row when either source knows about the device.
    public func makeRow(
        registry: RegistryDevice?,
        paired: MobilePairedMac?,
        pairedRecords: [MobilePairedMac] = [],
        presence: PresenceMap
    ) -> HiveComputer? {
        guard registry != nil || paired != nil else { return nil }
        let deviceID = registry?.deviceId ?? paired?.macDeviceID ?? ""
        let instances: [HiveComputerInstance]
        if let registry {
            instances = registry.instances.map { instance in
                let live = presence.instanceSummary(deviceId: deviceID, tag: instance.tag)
                let liveRoutes = presence.instance(deviceId: deviceID, tag: instance.tag)?.routes ?? []
                let pairedRoutes = pairedRecords.first(where: { $0.instanceTag == instance.tag })?.routes
                    ?? pairedRecords.first(where: { $0.instanceTag == nil })?.routes
                    ?? []
                return HiveComputerInstance(
                    tag: instance.tag,
                    routes: mergedRoutes(
                        live: liveRoutes,
                        registry: instance.routes,
                        paired: pairedRoutes
                    ),
                    lastSeenAt: max(live?.lastSeenAt ?? instance.lastSeenAt, instance.lastSeenAt),
                    isOnline: live?.online ?? false
                )
            }
        } else {
            instances = [
                HiveComputerInstance(
                    tag: paired?.instanceTag ?? "default",
                    routes: paired?.routes ?? [],
                    lastSeenAt: paired?.lastSeenAt ?? .distantPast,
                    isOnline: false
                )
            ]
        }
        let fallbackLastSeen = registry?.lastSeenAt ?? paired?.lastSeenAt
        return HiveComputer(
            deviceID: deviceID,
            displayName: paired?.customName?.nonEmpty
                ?? registry?.displayName?.nonEmpty
                ?? paired?.displayName?.nonEmpty
                ?? String(deviceID.prefix(8)),
            platform: registry?.platform,
            isThisComputer: deviceID == ownDeviceID,
            isPaired: paired != nil,
            isOwnedByCurrentUser: registry?.isOwnedByCurrentUser ?? true,
            presence: presenceState(
                for: deviceID,
                presence: presence,
                fallbackLastSeen: fallbackLastSeen
            ),
            buildLabel: presence.deviceSummary(deviceId: deviceID)?.buildLabel,
            instances: instances
        )
    }

    /// Whether the left row should sort before the right row.
    public func comesBefore(_ lhs: HiveComputer, _ rhs: HiveComputer) -> Bool {
        if lhs.isThisComputer != rhs.isThisComputer { return lhs.isThisComputer }
        if lhs.presence.isOnline != rhs.presence.isOnline {
            return lhs.presence.isOnline
        }
        let lhsSeen = lhs.presence.lastSeenAt ?? .distantPast
        let rhsSeen = rhs.presence.lastSeenAt ?? .distantPast
        if lhs.presence.isOnline == rhs.presence.isOnline, lhsSeen != rhsSeen {
            return lhsSeen > rhsSeen
        }
        return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
    }

    private func presenceState(
        for deviceID: String,
        presence: PresenceMap,
        fallbackLastSeen: Date?
    ) -> HiveComputerPresence {
        guard let summary = presence.deviceSummary(deviceId: deviceID) else {
            return .unknown(lastSeenAt: fallbackLastSeen)
        }
        if summary.online { return .online }
        let lastSeen = [summary.lastSeenAt, fallbackLastSeen].compactMap { $0 }.max()
        return .offline(lastSeenAt: lastSeen)
    }

    private func mergedRoutes(
        live: [CmxAttachRoute],
        registry: [CmxAttachRoute],
        paired: [CmxAttachRoute]
    ) -> [CmxAttachRoute] {
        var result: [CmxAttachRoute] = []
        for route in live + registry + paired
        where !result.contains(where: { $0.id == route.id }) {
            result.append(route)
        }
        return result.sorted { $0.priority < $1.priority }
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
