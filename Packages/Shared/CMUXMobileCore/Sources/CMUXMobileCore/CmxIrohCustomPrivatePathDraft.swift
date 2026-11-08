import Foundation

/// Device-local settings input for one Mac's explicit private addresses.
public struct CmxIrohCustomPrivatePathDraft: Equatable, Sendable {
    /// Maximum numeric addresses accepted for one Mac on one device.
    public static let maximumAddressCount = 8

    public let macDeviceID: String
    /// The authenticated app-build tag for this Mac process.
    public let instanceTag: String?
    public let macDisplayName: String
    public let addresses: [String]
    public let isEnabled: Bool

    public init(
        macDeviceID: String,
        instanceTag: String? = nil,
        macDisplayName: String,
        addresses: [String],
        isEnabled: Bool
    ) {
        self.macDeviceID = macDeviceID
        self.instanceTag = instanceTag
        self.macDisplayName = macDisplayName
        self.addresses = addresses
        self.isEnabled = isEnabled
    }
}
