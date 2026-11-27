import Foundation

/// The contract between the cmux app and the cmux Cloud tunnel system
/// extension. Both targets link this package so neither side spells the other's
/// keys by hand.
///
/// The app writes these into `NETunnelProviderProtocol.providerConfiguration`
/// when it saves the VPN configuration; the extension reads them back in
/// `startTunnel`. The provider configuration lives in the system's
/// NetworkExtension preferences (root-only), which is why the completed
/// wg-quick config, private key included, may travel through it: the
/// extension runs as root and has no access to the user's home directory or
/// keychain, and the preference store is at least as protected as the 0600
/// file the app keeps for the user-space tunnel.
/// lint:allow namespace-type: moved unchanged from the app target, where it was an internal static namespace; reshaping it is a separate change from this package move.
public enum CloudTunnelProviderConfigurationKeys {
    /// The completed wg-quick config text (`[Interface]` with `PrivateKey`
    /// filled in, plus the `[Peer]` section the control plane issued).
    public static let wgQuickConfig = "wgQuickConfig"
    /// Schema version of the provider configuration, so a future extension
    /// can refuse a shape it does not understand instead of misparsing it.
    public static let schemaVersion = "schemaVersion"
    /// The schema version this build writes and accepts.
    public static let currentSchemaVersion = 1
}

/// Messages the app sends the running provider through
/// `NETunnelProviderSession.sendProviderMessage`.
