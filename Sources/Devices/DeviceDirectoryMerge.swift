import CMUXMobileCore
import CmuxIrohTransport
import CmuxSurfaceCatalogModel
import Foundation

/// The pure merge behind the Devices directory: the pairing store's saved
/// Macs, durable registry rows, live presence instances, and the owners the
/// sync collection reports fold into one record per app instance, joining its
/// host identity to its v2 directory identity (``DeviceDirectoryIdentityIndex``).
/// Deterministic and clock-injected so every rule is unit-testable without a
/// network.
struct DeviceDirectoryMerge {
    struct Input: Sendable {
        var registry: [DeviceRegistryDirectoryClient.Device] = []
        /// Account-wide bindings from the same authenticated broker used by iOS.
        var authenticatedMacs: [DeviceDiscoveredMac] = []
        /// Automatic discovery admits only hosts that currently advertise Mac
        /// incoming access. Other sources enrich those rows, never add peers.
        var requiresAuthenticatedDiscovery = false
        var presence: [SurfaceDeviceInstanceID: DevicePresenceInstance] = [:]
        /// Whether the presence stream has delivered its snapshot, so a device
        /// absent from `presence` is known offline rather than unknown.
        var presenceLive = false
        /// Device UUID → owning Stack user id, from the `devices` sync collection.
        var owners: [String: String] = [:]
        /// Whether the sync collection has delivered a complete snapshot; until
        /// then a missing owner is "unknown", never "someone else".
        var ownersKnown = false
        /// Macs the person paired (Settings › Computers): listed and dialable
        /// even when the registry and presence are unavailable (local-first).
        var paired: [DevicePairedDevice] = []
        /// Records from the previous merge, kept so an instance presence forgets
        /// (its 24h offline tail expired) stays listed for the session.
        var previous: [DeviceDirectoryRecord] = []
        /// The viewer's device and build; no instance on this physical Mac is listed.
        var selfInstance: SurfaceDeviceInstanceID
        var currentUserID: String?
        /// The scope the directory reads: a personal team (the team id is the
        /// user id, or no team at all) contains only this account's devices.
        var resolvedTeamID: String?
    }

    private typealias RegistryEntry = (device: DeviceRegistryDirectoryClient.Device, instance: DeviceRegistryDirectoryClient.Instance)

    static func merge(_ input: Input, now: Date = Date()) -> [DeviceDirectoryRecord] {
        var hostRegistry: [SurfaceDeviceInstanceID: RegistryEntry] = [:]
        for device in input.registry where device.platform == "mac" && !device.isManual {
            for instance in device.instances {
                let id = SurfaceDeviceInstanceID(deviceID: device.deviceID, tag: instance.tag)
                hostRegistry[id] = (device, instance)
            }
        }
        let hostPresence = input.presence.filter { $0.value.platform.lowercased() == "mac" }
        let accountMacs = Dictionary(input.authenticatedMacs.map { (SurfaceDeviceInstanceID(deviceID: $0.deviceID, tag: $0.tag), $0) }, uniquingKeysWith: { first, _ in first })
        let hostPaired = Dictionary(input.paired.map { ($0.instance, $0) }, uniquingKeysWith: { first, _ in first })
        let retainedPrevious = input.previous.filter {
            $0.wasDiscovered || hostPaired[$0.instance] != nil
        }
        let hostPrevious = Dictionary(retainedPrevious.map { ($0.instance, $0) }, uniquingKeysWith: { first, _ in first })

        // One app instance carries a host identity and a directory identity.
        // Any source may advertise the endpoint that joins them, so the row is
        // decided per instance across all sources and then applied to each.
        // An instance on this physical Mac is never folded: it stays hidden.
        let identities = DeviceDirectoryIdentityIndex(authenticatedMacs: input.authenticatedMacs, previous: input.previous)
        var advertised: [SurfaceDeviceInstanceID: [CmxAttachRoute]] = [:]
        for (id, entry) in hostRegistry { advertised[id, default: []] += entry.instance.routes }
        for (id, instance) in hostPresence { advertised[id, default: []] += instance.routes ?? [] }
        for (id, device) in hostPaired { advertised[id, default: []] += device.routes }
        for (id, record) in hostPrevious { advertised[id, default: []] += record.routes }
        var rows: [SurfaceDeviceInstanceID: SurfaceDeviceInstanceID] = [:]
        var hostIDsByRow: [SurfaceDeviceInstanceID: [SurfaceDeviceInstanceID]] = [:]
        for (id, routes) in advertised where id.isVisible(from: input.selfInstance) {
            let row = identities.rowInstance(for: id, advertising: routes)
            rows[id] = row
            if row != id { hostIDsByRow[row, default: []].append(id) }
        }
        let registryInstances = fold(hostRegistry, onto: rows) { candidate, existing in
            (candidate.instance.lastSeenAt ?? candidate.device.lastSeenAt ?? .distantPast)
                > (existing.instance.lastSeenAt ?? existing.device.lastSeenAt ?? .distantPast)
        }
        let presenceMacs = fold(hostPresence, onto: rows) { candidate, existing in
            candidate.online != existing.online ? candidate.online : candidate.lastSeenAt > existing.lastSeenAt
        }
        let pairedByID = fold(hostPaired, onto: rows) { _, _ in false }
        let previousByID = fold(hostPrevious, onto: rows) { candidate, existing in
            candidate.directoryEndpoint != nil && existing.directoryEndpoint == nil
        }

        var ids = Set(accountMacs.keys)
        if !input.requiresAuthenticatedDiscovery {
            // Explicit legacy pairing remains available without the v2 client.
            ids.formUnion(registryInstances.keys)
            ids.formUnion(presenceMacs.keys)
            ids.formUnion(pairedByID.keys)
            ids.formUnion(previousByID.keys)
        }
        ids = ids.filter { $0.isVisible(from: input.selfInstance) }

        let personalScope = input.resolvedTeamID == nil || input.resolvedTeamID == input.currentUserID

        let records = ids.map { id -> DeviceDirectoryRecord in
            let registry = registryInstances[id]
            let accountMac = accountMacs[id]
            let presence = presenceMacs[id]
            let paired = pairedByID[id]
            let previous = previousByID[id]

            let presenceState: DeviceDirectoryPresence
            if let presence {
                presenceState = presence.online ? .online : .offline
            } else if input.presenceLive {
                presenceState = .offline
            } else {
                presenceState = previous?.presenceState ?? .unknown
            }
            let isOnline = presenceState == .online

            // Saved pairing routes lead: they are the ones with a grant. Live
            // presence routes follow while online, the registry's after.
            var routes: [CmxAttachRoute] = []
            func append(_ candidates: [CmxAttachRoute]) {
                for route in candidates where !routes.contains(where: { isSameRoute($0, route) }) {
                    routes.append(route)
                }
            }
            if let accountMac, let route = try? CmxAttachRoute(
                id: "iroh-\(accountMac.bindingID)", kind: .iroh,
                endpoint: .peer(identity: accountMac.endpointID, pathHints: accountMac.pathHints),
                priority: 0
            ) { append([route]) }
            append(paired?.routes ?? [])
            if isOnline { append(presence?.routes ?? []) }
            append(registry?.instance.routes ?? [])
            if !isOnline { append(presence?.routes ?? []) }
            // An unpair also revokes routes retained from the old grant. A
            // discovered row can remain, but only with its discovery routes.
            if routes.isEmpty, previous?.isPaired != true || paired != nil {
                routes = previous?.routes ?? []
            }

            let presenceSeen = presence.map { Date(timeIntervalSince1970: $0.lastSeenAt / 1000) }
            let lastSeenAt = [presenceSeen, registry?.instance.lastSeenAt, registry?.device.lastSeenAt, paired?.lastSeenAt, previous?.lastSeenAt]
                .compactMap { $0 }
                .max()
            // The `devices` collection pins owners by host device id.
            let ownerIDs = [id] + (hostIDsByRow[id] ?? []).sorted { $0.wireValue < $1.wireValue }
            let pinnedOwner = ownerIDs.lazy.compactMap { input.owners[$0.deviceID] }.first
            let ownerUserID = pinnedOwner ?? (input.ownersKnown ? nil : previous?.ownerUserID)
            let trust: SurfaceDevicePresence.AccountTrust
            if accountMac != nil || paired != nil {
                // Pairing verified the host's authenticated identity under this
                // account; the store is scoped to it.
                trust = .sameAccount
            } else if let ownerUserID, let currentUserID = input.currentUserID {
                trust = ownerUserID == currentUserID ? .sameAccount : .otherAccount
            } else if personalScope {
                // A personal team holds only this account's devices; the owner
                // pin adds nothing the scope does not already prove.
                trust = .sameAccount
            } else if input.ownersKnown, ownerUserID == nil {
                trust = .unknown
            } else {
                trust = previous?.accountTrust ?? .unknown
            }
            let name = [accountMac?.displayName, presence?.displayName, paired?.displayName, registry?.device.displayName, previous?.deviceName]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
                ?? String(id.deviceID.prefix(8))
            return DeviceDirectoryRecord(
                instance: id,
                deviceName: name,
                platform: "mac",
                bundleID: presence?.bundleId ?? previous?.bundleID,
                presenceState: presenceState,
                isPaired: paired != nil,
                wasDiscovered: accountMac != nil || registry != nil || presence != nil || previous?.wasDiscovered == true,
                lastSeenAt: lastSeenAt,
                routes: routes,
                ownerUserID: ownerUserID,
                accountTrust: trust,
                directoryEndpoint: accountMac?.endpointID ?? previous?.directoryEndpoint,
                controlPlaneSupport: accountMac.map { $0.controlPlaneSupportsMacPeers ? .supported : .outdated }
                    ?? previous?.controlPlaneSupport ?? .notApplicable
            )
        }
        return records.sorted { lhs, rhs in
            let lhsRank = Self.rank(lhs.presenceState), rhsRank = Self.rank(rhs.presenceState)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            let byName = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
            if byName != .orderedSame { return byName == .orderedAscending }
            return lhs.instance.wireValue < rhs.instance.wireValue
        }
    }

    /// Re-keys host-keyed facts onto their rows. `outranks` settles two facts
    /// that land on one row; candidates arrive in wire order, so ties are stable.
    private static func fold<Value>(
        _ values: [SurfaceDeviceInstanceID: Value],
        onto rows: [SurfaceDeviceInstanceID: SurfaceDeviceInstanceID],
        outranks: (_ candidate: Value, _ existing: Value) -> Bool
    ) -> [SurfaceDeviceInstanceID: Value] {
        var folded: [SurfaceDeviceInstanceID: Value] = [:]
        for (id, value) in values.sorted(by: { $0.key.wireValue < $1.key.wireValue }) {
            let row = rows[id] ?? id
            if let existing = folded[row], !outranks(value, existing) { continue }
            folded[row] = value
        }
        return folded
    }

    /// Two routes to one iroh peer are one route: hints change, the peer does not.
    private static func isSameRoute(_ lhs: CmxAttachRoute, _ rhs: CmxAttachRoute) -> Bool {
        if lhs.id == rhs.id || lhs.endpoint == rhs.endpoint { return true }
        guard lhs.kind == .iroh, rhs.kind == .iroh,
              case .peer(let left, _) = lhs.endpoint, case .peer(let right, _) = rhs.endpoint else { return false }
        return left == right
    }

    /// Online first, then devices presence has not reported on, then offline.
    private static func rank(_ state: DeviceDirectoryPresence) -> Int {
        switch state {
        case .online: return 0
        case .unknown: return 1
        case .offline: return 2
        }
    }
}
