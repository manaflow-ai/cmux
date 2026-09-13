import Foundation

/// Immutable preferences rendered by the always-available My Devices menu.
struct CloudTreeDevicesSection: Equatable, Sendable {
    var count: Int = 0
    var discoveryEnabled: Bool = true
    var incomingAccessEnabled: Bool = true
    var discoveryManaged: Bool = false
    var incomingAccessManaged: Bool = false
}
