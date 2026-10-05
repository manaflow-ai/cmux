import CMUXMobileCore
import CmuxIrohTransport
import CmuxIrxTransport
import Foundation

/// Which directory authorized an outgoing Mac target. A dial's post-admit
/// recheck, IO checks and enforcement all resolve against this same source,
/// so an account-resolved target can never be confirmed by a team row (or the
/// reverse) after the NAT preAuthorization barrier.
enum DeviceDirectorySource: Sendable, Equatable {
    case team
    case account
}

/// One authorized outgoing target and the relay set its directory vouches for.
struct DeviceResolvedMacTarget: Sendable {
    let record: V2DeviceRecord
    let source: DeviceDirectorySource
    let relayURLs: [String]
}

extension DeviceIrxClient {
    /// Resolves an exact Mac intent.
    ///
    /// With no `source`, a device whose qualifying account row exists (listed,
    /// cross-team, unambiguous: its latest publish came from another team)
    /// resolves only in the account directory, the same row discovery shows;
    /// any other key for that device, such as the team record's old key, is
    /// refused. Every other device resolves in the team directory exactly as
    /// before the account directory existed. With a `source`, only that
    /// directory is consulted.
    static func resolveTarget(
        intent: IrxMacPeerAuthorization,
        source: DeviceDirectorySource?,
        cache: V2CachedState,
        account: AccountMacDirectorySnapshot?,
        localIdentity: V2Identity,
        now: Date
    ) throws -> DeviceResolvedMacTarget {
        func fromAccount() throws -> DeviceResolvedMacTarget {
            // This Mac's own team directory stays authoritative for every path:
            // a stale one is final even for a fresh cross-team account row.
            guard let account, teamDirectoryIsFresh(cache: cache, localIdentity: localIdentity, now: now) else {
                throw IrxMacPeerAuthorization.Failure.staleDirectory
            }
            let record = try IrxAccountMacPeerAuthorization(intent).resolve(
                account: account, cache: cache, localIdentity: localIdentity, now: now)
            return DeviceResolvedMacTarget(record: record, source: .account, relayURLs: account.directory.relayURLs)
        }
        if source == .account { return try fromAccount() }
        if source == nil, accountOwnedRow(deviceID: intent.deviceID, tag: intent.tag, cache: cache,
                                          account: account, localIdentity: localIdentity, now: now) != nil {
            return try fromAccount()
        }
        let record = try intent.resolve(cache: cache, localIdentity: localIdentity, now: now)
        return DeviceResolvedMacTarget(record: record, source: .team, relayURLs: cache.directory?.relayURLs ?? [])
    }

    /// Whether this Mac's complete team directory is current, with the same
    /// checks `IrxMacPeerAuthorization` applies before any team dial.
    static func teamDirectoryIsFresh(cache: V2CachedState, localIdentity: V2Identity, now: Date) -> Bool {
        guard let directory = cache.directory, directory.nextCursor == nil,
              directory.teamID == localIdentity.teamID else { return false }
        let seconds = now.timeIntervalSince1970
        return seconds >= Double(directory.issuedAt) && seconds < Double(directory.permissionExpiresAt)
    }

    /// The account row that owns a device for discovery and dialing, or nil.
    /// It qualifies only when the account authorization accepts it: listed
    /// (the service drops rows whose team lease lapsed), from another team
    /// than this Mac's, and the only row for that device and build.
    static func accountOwnedRow(
        deviceID: String,
        tag: String,
        cache: V2CachedState,
        account: AccountMacDirectorySnapshot?,
        localIdentity: V2Identity,
        now: Date
    ) -> V2DeviceRecord? {
        guard let account, teamDirectoryIsFresh(cache: cache, localIdentity: localIdentity, now: now) else { return nil }
        let candidates = account.directory.macs.filter {
            $0.descriptor.identity.deviceID.lowercased() == deviceID.lowercased()
                && $0.descriptor.identity.buildTag == tag
        }
        guard candidates.count == 1, let row = candidates.first else { return nil }
        return try? IrxAccountMacPeerAuthorization(deviceID: deviceID, tag: tag, endpointID: row.descriptor.endpointID)
            .resolve(account: account, cache: cache, localIdentity: localIdentity, now: now)
    }

    /// Projects authorized Macs from the team and account directories into one
    /// list, deduplicated by (device, build tag). A qualifying account row
    /// (listed, cross-team, unambiguous) replaces the team row; every other
    /// device keeps its team row.
    static func displayBindings(cache: V2CachedState, account: AccountMacDirectorySnapshot?, now: Date) -> [DeviceDiscoveredMac] {
        let team = displayBindings(cache: cache, now: now)
        guard let account, teamDirectoryIsFresh(cache: cache, localIdentity: cache.identity, now: now) else { return team }
        let accountRows: [DeviceDiscoveredMac] = account.directory.macs.compactMap { record in
            let device = record.descriptor
            let intent = IrxAccountMacPeerAuthorization(deviceID: device.identity.deviceID,
                tag: device.identity.buildTag, endpointID: device.endpointID)
            guard (try? intent.resolve(account: account, cache: cache, localIdentity: cache.identity, now: now)) != nil,
                  let endpoint = try? CmxIrohPeerIdentity(endpointID: device.endpointID) else { return nil }
            let expiry = min(now.addingTimeInterval(1800),
                Date(timeIntervalSince1970: Double(account.directory.permissionExpiresAt)))
            let hints = device.metadata.relayURLs.filter { account.directory.relayURLs.contains($0) }.prefix(2).compactMap {
                try? CmxIrohPathHint(kind: .relayURL, value: $0, source: .native,
                    privacyScope: .publicInternet, observedAt: now, expiresAt: expiry)
            }
            return DeviceDiscoveredMac(bindingID: record.deviceRecordID,
                deviceID: device.identity.deviceID.lowercased(), tag: device.identity.buildTag,
                displayName: device.metadata.displayName, endpointID: endpoint, pathHints: hints,
                controlPlaneSupportsMacPeers: account.directory.supportsAccountPeers)
        }
        guard !accountRows.isEmpty else { return team }
        // Every account row here already qualifies (listed, cross-team,
        // unambiguous), so the Mac's latest publish came from another team and
        // its row replaces the team row for the same device and build. That
        // team row is the key the Mac held while it was in this team. Dialing
        // resolves the same way (resolveTarget), so display and dial agree.
        func key(_ mac: DeviceDiscoveredMac) -> String { mac.deviceID + "\u{0}" + mac.tag }
        var byKey: [String: DeviceDiscoveredMac] = [:]
        for row in accountRows { byKey[key(row)] = row }
        var merged: [DeviceDiscoveredMac] = []
        var emitted = Set<String>()
        for row in team where emitted.insert(key(row)).inserted {
            merged.append(byKey[key(row)] ?? row)
        }
        for row in accountRows where emitted.insert(key(row)).inserted {
            merged.append(row)
        }
        return merged
    }
}
