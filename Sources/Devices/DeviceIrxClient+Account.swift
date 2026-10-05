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
    /// With no `source`, the account directory is tried first (it names the
    /// peer's current endpoint even when that Mac selected another team), then
    /// the team directory. With a `source`, only that directory is consulted.
    /// The team failure is the one surfaced, so behavior without an account
    /// directory is exactly the team-only behavior.
    static func resolveTarget(
        intent: IrxMacPeerAuthorization,
        source: DeviceDirectorySource?,
        cache: V2CachedState,
        account: AccountMacDirectorySnapshot?,
        localIdentity: V2Identity,
        now: Date
    ) throws -> DeviceResolvedMacTarget {
        if source != .team, let account {
            do {
                let record = try IrxAccountMacPeerAuthorization(intent).resolve(
                    account: account, cache: cache, localIdentity: localIdentity, now: now)
                return DeviceResolvedMacTarget(record: record, source: .account, relayURLs: account.directory.relayURLs)
            } catch {
                if source == .account { throw error }
            }
        } else if source == .account {
            throw IrxMacPeerAuthorization.Failure.staleDirectory
        }
        let record = try intent.resolve(cache: cache, localIdentity: localIdentity, now: now)
        return DeviceResolvedMacTarget(record: record, source: .team, relayURLs: cache.directory?.relayURLs ?? [])
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
        var byKey: [String: DeviceDiscoveredMac] = [:]
        for row in accountRows where byKey[key(row)] == nil { byKey[key(row)] = row }
        var merged: [DeviceDiscoveredMac] = []
        var emitted = Set<String>()
        for row in team {
            let rowKey = key(row)
            guard emitted.insert(rowKey).inserted else { continue }
            merged.append(byKey[rowKey] ?? row)
        }
        for row in accountRows where emitted.insert(key(row)).inserted {
            merged.append(row)
        }
        return merged
    }
}
