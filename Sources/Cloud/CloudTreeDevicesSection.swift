import Foundation

/// Immutable preferences shared by the My Devices section menu and empty state.
struct CloudTreeDevicesSection: Equatable, Sendable {
    var count: Int = 0
    var discoveryEnabled: Bool = true
    var incomingAccessEnabled: Bool = false
    var discoveryManaged: Bool = false
    var incomingAccessManaged: Bool = false
}
