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
    /// With no `source`, the team directory decides first, exactly as before
    /// the account directory existed. Only an endpoint the team directory does
    /// not list (`.unavailable`) is tried in the account directory, which
    /// holds only Macs of the same user in other teams. Every other team
    /// failure (stale, revoked, mismatched) is final. With a `source`, only
    /// that directory is consulted.
    static func resolveTarget(
        intent: IrxMacPeerAuthorization,
        source: DeviceDirectorySource?,
        cache: V2CachedState,
        account: AccountMacDirectorySnapshot?,
        localIdentity: V2Identity,
        now: Date
    ) throws -> DeviceResolvedMacTarget {
        func fromAccount() throws -> DeviceResolvedMacTarget {
            guard let account else { throw IrxMacPeerAuthorization.Failure.staleDirectory }
            let record = try IrxAccountMacPeerAuthorization(intent).resolve(
                account: account, cache: cache, localIdentity: localIdentity, now: now)
            return DeviceResolvedMacTarget(record: record, source: .account, relayURLs: account.directory.relayURLs)
        }
        if source == .account { return try fromAccount() }
        do {
            let record = try intent.resolve(cache: cache, localIdentity: localIdentity, now: now)
            return DeviceResolvedMacTarget(record: record, source: .team, relayURLs: cache.directory?.relayURLs ?? [])
        } catch IrxMacPeerAuthorization.Failure.unavailable where source == nil && account != nil {
            do { return try fromAccount() } catch { throw IrxMacPeerAuthorization.Failure.unavailable }
        }
    }

    /// Projects authorized Macs from the team and account directories into one
    /// list, deduplicated by (device, build tag). The account row wins: it is
    /// returned only while fresh, and it names the endpoint the peer uses now,
    /// while a team row can still carry a key from when that Mac selected this team.
    static func displayBindings(cache: V2CachedState, account: AccountMacDirectorySnapshot?, now: Date) -> [DeviceDiscoveredMac] {
        let team = displayBindings(cache: cache, now: now)
        guard let account else { return team }
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
        func key(_ mac: DeviceDiscoveredMac) -> String { mac.deviceID + "\u{0}" + mac.tag }
        // One installation has one account row (the service keys rows by
        // device, namespace and build). Two rows for one key are ambiguous,
        // so neither is used rather than whichever the server sent first.
        var counts: [String: Int] = [:]
        for row in accountRows { counts[key(row), default: 0] += 1 }
        var byKey: [String: DeviceDiscoveredMac] = [:]
        for row in accountRows where counts[key(row)] == 1 { byKey[key(row)] = row }
        var merged: [DeviceDiscoveredMac] = []
        var emitted = Set<String>()
        for row in team {
            let rowKey = key(row)
            guard emitted.insert(rowKey).inserted else { continue }
            // An account row exists only for a Mac whose latest publish came
            // from another team, so it names the endpoint that Mac uses now;
            // the team row for it is the key it held while in this team. When
            // both name the same endpoint the team row is kept unchanged.
            if let replacement = byKey[rowKey], replacement.endpointID != row.endpointID {
                merged.append(replacement)
            } else {
                merged.append(row)
            }
        }
        for row in accountRows where byKey[key(row)] != nil && emitted.insert(key(row)).inserted {
            merged.append(row)
        }
        return merged
    }
}
