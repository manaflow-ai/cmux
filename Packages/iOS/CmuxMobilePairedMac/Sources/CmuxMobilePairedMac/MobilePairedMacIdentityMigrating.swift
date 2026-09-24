public import CMUXMobileCore
public import Foundation

/// Current directory evidence, supplied only by authenticated v2 discovery.
/// This is metadata for migration, never a grant to connect to a peer.
public struct MobilePairedMacDirectoryIdentity: Sendable {
    public let deviceID: String
    public let instanceTag: String
    public let routes: [CmxAttachRoute]

    public init(deviceID: String, instanceTag: String, routes: [CmxAttachRoute]) {
        self.deviceID = cmxCanonicalDeviceID(deviceID)
        self.instanceTag = instanceTag
        self.routes = routes
    }

    public var pairingID: String {
        MobilePairedMac.pairingID(macDeviceID: deviceID, instanceTag: instanceTag)
    }
}

/// A durable replacement used to move device-local preferences after the SQL
/// transaction. Returning it again after a restart makes that step retry-safe.
public struct MobilePairedMacIdentityReplacement: Equatable, Sendable {
    public let oldPairingID: String
    public let newPairingID: String

    public init(oldPairingID: String, newPairingID: String) {
        self.oldPairingID = oldPairingID
        self.newPairingID = newPairingID
    }
}

/// Injected only for distributions with pre-v2 saved computers. Ordinary
/// persistence and App Store installs do not run this upgrade operation.
public protocol MobilePairedMacIdentityMigrating: Sendable {
    func reconcileLegacyIdentities(
        with directory: [MobilePairedMacDirectoryIdentity],
        stackUserID: String,
        teamID: String?
    ) async throws -> [MobilePairedMacIdentityReplacement]
}
