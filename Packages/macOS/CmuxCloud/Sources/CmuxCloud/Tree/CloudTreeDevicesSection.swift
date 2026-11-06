import CmuxSettings
import Foundation

/// Immutable preferences shared by the My Devices section menu and empty state.
public struct CloudTreeDevicesSection: Equatable, Sendable {
    public init(
        count: Int = 0,
        discoveryEnabled: Bool = true,
        incomingAccessEnabled: Bool = false,
        discoveryManaged: Bool = false,
        incomingAccessManaged: Bool = false,
        available: Bool = true,
        isRefreshing: Bool = false,
        discoveryPhase: DeviceListDiscoveryPhase = .resolved
    ) {
        self.count = count
        self.discoveryEnabled = discoveryEnabled
        self.incomingAccessEnabled = incomingAccessEnabled
        self.discoveryManaged = discoveryManaged
        self.incomingAccessManaged = incomingAccessManaged
        self.available = available
        self.isRefreshing = isRefreshing
        self.discoveryPhase = discoveryPhase
    }

    public var count: Int = 0
    public var discoveryEnabled: Bool = true
    public var incomingAccessEnabled: Bool = false
    public var discoveryManaged: Bool = false
    public var incomingAccessManaged: Bool = false
    /// Whether Cloud availability permits either device preference.
    public var available: Bool = true
    /// A refresh of the devices list is running; the header's refresh icon spins.
    public var isRefreshing: Bool = false
    /// Whether the account directory has finished a read. Defaults to resolved
    /// so fixtures that only care about row shape keep the settled empty copy.
    public var discoveryPhase: DeviceListDiscoveryPhase = .resolved

    /// The status row under the devices, or none once a Mac is listed.
    public var emptyClaim: DeviceListEmptyClaim {
        DeviceListDiscoveryPresentation.claim(
            deviceCount: count,
            discoveryEnabled: discoveryEnabled,
            phase: discoveryPhase
        )
    }

    /// Both independent actions stay visible below the devices, preceded by
    /// one status line when the list has no Mac rows yet.
    public var inlineRowCount: Int {
        (count == 0 ? 1 : 0) + 2
    }
}
