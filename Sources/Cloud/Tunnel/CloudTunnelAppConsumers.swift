import Foundation

/// Cloud panes use the user-space hub; none keeps the optional system VPN alive.
/// Explicit VPN requests pin it until the user disconnects.
struct CloudTunnelAppConsumers: CloudTunnelConsumerSource {
    /// No cmux-owned pane uses the system-wide tunnel as a live consumer.
    func liveConsumerCount() async -> Int {
        0
    }
}
