import Foundation

public struct CloudPrivateNetworkUse: Sendable, Equatable {
    public init(
        machineID: String,
        purpose: CloudPrivateNetworkPurpose
    ) {
        self.machineID = machineID
        self.purpose = purpose
    }

    public let machineID: String
    public let purpose: CloudPrivateNetworkPurpose
}
