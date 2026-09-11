import Foundation

/// Cloud panes use the user-space hub; none keeps the optional system VPN alive.
/// Explicit VPN requests pin it until the user disconnects.
struct CloudTunnelAppConsumers: CloudTunnelConsumerSource {
    func liveConsumerCount() async -> Int {
        0
    }
}
