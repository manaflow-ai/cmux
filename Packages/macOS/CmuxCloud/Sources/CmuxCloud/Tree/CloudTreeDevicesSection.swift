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

    /// Rows the section's inline controls show: "No other Macs yet" while no
    /// other Mac is listed, then one action per opt-in that is still off.
    /// Zero means the controls row has nothing to show and is omitted.
    public var inlineRowCount: Int {
        (count == 0 ? 1 : 0) + (discoveryEnabled ? 0 : 1) + (incomingAccessEnabled ? 0 : 1)
    }
}
