import Foundation

/// Immutable preferences shared by the My Devices section menu and empty state.
public struct CloudTreeDevicesSection: Equatable, Sendable {
    public init(
        count: Int = 0,
        discoveryEnabled: Bool = true,
        incomingAccessEnabled: Bool = false,
        discoveryManaged: Bool = false,
        incomingAccessManaged: Bool = false,
        available: Bool = true
    ) {
        self.count = count
        self.discoveryEnabled = discoveryEnabled
        self.incomingAccessEnabled = incomingAccessEnabled
        self.discoveryManaged = discoveryManaged
        self.incomingAccessManaged = incomingAccessManaged
        self.available = available
    }

    public var count: Int = 0
    public var discoveryEnabled: Bool = true
    public var incomingAccessEnabled: Bool = false
    public var discoveryManaged: Bool = false
    public var incomingAccessManaged: Bool = false
    /// Whether Cloud/Beta availability permits either device preference.
    public var available: Bool = true

    /// Both independent actions stay visible below the devices, preceded by
    /// "No other Macs yet" when the list is empty.
    public var inlineRowCount: Int {
        (count == 0 ? 1 : 0) + 2
    }
}
