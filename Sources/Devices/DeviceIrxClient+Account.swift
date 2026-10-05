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
    /// list, deduplicated by (device, build tag). A valid team row always wins;
    /// account rows add only Macs the team directory cannot reach.
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
        // A Mac the current team directory validly lists keeps its team row.
        // An account row only adds a Mac the team cannot reach (a key the team
        // does not list, or no valid team row), so a stale account row can
        // never hide a live team endpoint. Ambiguous account rows were already
        // refused by IrxAccountMacPeerAuthorization.
        func key(_ mac: DeviceDiscoveredMac) -> String { mac.deviceID + "\u{0}" + mac.tag }
        var emitted = Set(team.map(key))
        var merged = team
        for row in accountRows where emitted.insert(key(row)).inserted {
            merged.append(row)
        }
        return merged
    }
}
