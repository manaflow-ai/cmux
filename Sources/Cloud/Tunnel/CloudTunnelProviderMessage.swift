import Foundation

enum CloudTunnelProviderMessage {
    /// Ask for the live WireGuard runtime configuration (the `wg show`
    /// equivalent: peers, last handshake, transfer counters). The reply is the
    /// UTF-8 text WireGuardKit produces, or empty when the tunnel is down.
    static let runtimeConfiguration = Data([0])
}
