internal import CMUXMobileCore
internal import Foundation

/// One exact stored paired-Mac row identity — the four-part owner key a
/// `removeExactScope` deletion targets — as a value, so several rows can be
/// removed in one batched call.
public struct MobilePairedMacExactScope: Sendable, Equatable, Hashable {
    public let macDeviceID: String
    public let instanceTag: String?
    public let stackUserID: String?
    public let teamID: String?

    public init(
        macDeviceID: String,
        instanceTag: String?,
        stackUserID: String?,
        teamID: String?
    ) {
        let identity = CmxMacAppInstanceIdentity(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag
        )
        self.macDeviceID = identity.macDeviceID
        self.instanceTag = identity.instanceTag
        self.stackUserID = stackUserID
        self.teamID = teamID
    }

    /// Creates the exact local row scope carried by a paired-Mac value.
    public init(_ mac: MobilePairedMac) {
        self.init(
            macDeviceID: mac.macDeviceID,
            instanceTag: mac.instanceTag,
            stackUserID: mac.stackUserID,
            teamID: mac.teamID
        )
    }

    /// The in-memory pairing key for this row inside the owner scope.
    public var pairingID: String {
        MobilePairedMac.pairingID(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag
        )
    }
}

extension MobilePairedMac {
    /// The full four-field owner identity used by exact persistence operations.
    public var exactScope: MobilePairedMacExactScope {
        MobilePairedMacExactScope(self)
    }
}
