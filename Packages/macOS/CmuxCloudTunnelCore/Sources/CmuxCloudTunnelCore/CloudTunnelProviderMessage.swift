public import Foundation

/// Messages the app sends the running provider through
/// `NETunnelProviderSession.sendProviderMessage`.
/// lint:allow namespace-type: moved unchanged from the app target, where it was an internal static namespace; reshaping it is a separate change from this package move.
public enum CloudTunnelProviderMessage {
    /// Ask for the live WireGuard runtime configuration (the `wg show`
    /// equivalent: peers, last handshake, transfer counters). The reply is the
    /// UTF-8 text WireGuardKit produces, or empty when the tunnel is down.
    public static let runtimeConfiguration = Data([0])
}
