import CMUXMobileCore
import CmuxIrohTransport
import CmuxIrxTransport
import Foundation

extension DeviceIrxClient {
    /// Projects only currently authorized v2 Macs into immutable directory rows.
    static func displayBindings(cache: V2CachedState, now: Date) -> [DeviceDiscoveredMac] {
        guard let directory = cache.directory else { return [] }
        return directory.devices.compactMap { record in
            let device = record.descriptor
            guard (try? IrxMacPeerAuthorization(deviceID: device.identity.deviceID,
                tag: device.identity.buildTag, endpointID: device.endpointID)
                .resolve(cache: cache, localIdentity: cache.identity, now: now)) != nil else { return nil }
            let hints = device.metadata.relayURLs.filter { directory.relayURLs.contains($0) }.prefix(2).compactMap {
                try? CmxIrohPathHint(kind: .relayURL, value: $0, source: .native,
                    privacyScope: .publicInternet, observedAt: now,
                    expiresAt: min(now.addingTimeInterval(1800), Date(timeIntervalSince1970: Double(directory.permissionExpiresAt))))
            }
            guard let endpoint = try? CmxIrohPeerIdentity(endpointID: device.endpointID) else { return nil }
            return DeviceDiscoveredMac(bindingID: record.deviceRecordID,
                deviceID: device.identity.deviceID.lowercased(), tag: device.identity.buildTag,
                displayName: device.metadata.displayName, endpointID: endpoint, pathHints: hints)
        }
    }

    static func relayCredentials(_ cache: V2CachedState, at now: Date) -> [IrxRelayCredential] {
        guard !cache.authorityRevoked else { return [] }
        return cache.relayCredentials.compactMap { credential in
            let expiry = Date(timeIntervalSince1970: Double(credential.expiresAt))
            guard expiry > now else { return nil }
            return IrxRelayCredential(relayURL: credential.relayURL, token: credential.token,
                expiresAt: expiry, refreshAfter: Date(timeIntervalSince1970: Double(credential.refreshAfter)))
        }
    }
}
