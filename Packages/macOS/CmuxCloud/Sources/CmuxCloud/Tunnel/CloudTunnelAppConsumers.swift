import Foundation

/// Cloud panes use the user-space hub; none keeps the optional system VPN alive.
/// Explicit VPN requests pin it until the user disconnects.
public struct CloudTunnelAppConsumers: CloudTunnelConsumerSource, Sendable {
    public init() {}

    public func liveConsumerCount() async -> Int {
        0
    }
}
