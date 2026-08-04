import Foundation

/// Device-local settings input for one Mac's explicit private addresses.
public struct CmxIrohCustomPrivatePathDraft: Equatable, Sendable {
    /// Maximum numeric addresses accepted for one Mac on one device.
    public static let maximumAddressCount = 8

    public let macDeviceID: String
    public let macDisplayName: String
    public let addresses: [String]
    public let isEnabled: Bool

    public init(
        macDeviceID: String,
        macDisplayName: String,
        addresses: [String],
        isEnabled: Bool
    ) {
        self.macDeviceID = macDeviceID
        self.macDisplayName = macDisplayName
        self.addresses = addresses
        self.isEnabled = isEnabled
    }
}
