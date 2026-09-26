import Foundation

/// Immutable preferences shared by the My Devices section menu and empty state.
public struct CloudTreeDevicesSection: Equatable, Sendable {
    public init(
        count: Int = 0,
        discoveryEnabled: Bool = true,
        incomingAccessEnabled: Bool = false,
        discoveryManaged: Bool = false,
        incomingAccessManaged: Bool = false
    ) {
        self.count = count
        self.discoveryEnabled = discoveryEnabled
        self.incomingAccessEnabled = incomingAccessEnabled
        self.discoveryManaged = discoveryManaged
        self.incomingAccessManaged = incomingAccessManaged
    }

    public var count: Int = 0
    public var discoveryEnabled: Bool = true
    public var incomingAccessEnabled: Bool = false
    public var discoveryManaged: Bool = false
    public var incomingAccessManaged: Bool = false
}
