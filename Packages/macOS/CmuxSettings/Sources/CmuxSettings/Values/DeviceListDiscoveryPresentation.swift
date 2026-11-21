import Foundation

/// How far the account device list has gotten.
///
/// ``discovering`` is the window before the first directory read finishes.
/// An empty array in that window is "not loaded yet", not "this account has
/// no other Macs".
public enum DeviceListDiscoveryPhase: Equatable, Sendable {
    case discovering
    case resolved
    case unreachable
}

/// What an empty device row is allowed to say.
public enum DeviceListEmptyClaim: Equatable, Sendable {
    /// The list has rows. No empty or progress sentence belongs in their place.
    case hidden
    /// Discovery is still running. Do not claim the account has no Macs.
    case discovering
    /// The list could not be read and there is nothing to keep showing.
    case unreachable
    /// A completed read found no other Macs.
    case empty
}

/// Chooses the device-list empty row for Settings and the My Devices sidebar.
public enum DeviceListDiscoveryPresentation {
    public static func claim(
        deviceCount: Int,
        discoveryEnabled: Bool,
        phase: DeviceListDiscoveryPhase
    ) -> DeviceListEmptyClaim {
        guard deviceCount == 0 else { return .hidden }
        // Discovery off is a preference, not an in-progress search. The
        // existing empty sentence stays next to the switch that turns it on.
        guard discoveryEnabled else { return .empty }
        switch phase {
        case .discovering:
            return .discovering
        case .unreachable:
            return .unreachable
        case .resolved:
            return .empty
        }
    }
}
