import Foundation

/// Mobile integration settings for pairing and syncing with cmux on iOS.
public struct MobileCatalogSection: SettingCatalogSection {
    /// How this Mac advertises itself to paired iOS devices: cmux-hosted iroh
    /// (default), the user's own iroh relay, or Tailscale. A strict single
    /// choice; the Mac publishes only the chosen lane's routes. The user picks
    /// this during pairing/onboarding (and when adding a new Mac). Replaces the
    /// legacy `mobile.iOSPairingHost.enabled` / `mobile.iOSIrohHost.enabled`
    /// booleans, which ``MobileTransportModeMigration`` derives this from once.
    public let iOSTransportMode = DefaultsKey<MobileTransportMode>(
        id: "mobile.iOSTransportMode",
        defaultValue: .cmuxRelay,
        userDefaultsKey: "mobile.iOSTransportMode"
    )

    /// Relay URL for ``MobileTransportMode/ownRelay``: the `https://` address of
    /// an `iroh-relay` the user runs themselves. Ignored in the other modes.
    /// Empty until the user sets one.
    public let iOSIrohRelayURL = DefaultsKey<String>(
        id: "mobile.iOSIrohRelayURL",
        defaultValue: "",
        userDefaultsKey: "mobile.iOSIrohRelayURL"
    )

    /// TCP port the Mac-side iOS pairing listener prefers to bind.
    ///
    /// This is a *preference*: if the port is already in use the listener
    /// falls back to an OS-assigned ephemeral port, and the iOS app is always
    /// handed the actual bound port (so pairing still works). Configure a fixed
    /// port when you need predictable firewall rules or to avoid a conflict.
    /// The default mirrors `CmxMobileDefaults.defaultHostPort`, the protocol
    /// default mobile clients dial when a pairing payload omits a port.
    public let iOSPairingPort = DefaultsKey<Int>(
        id: "mobile.iOSPairingHost.port",
        defaultValue: 58_465,
        userDefaultsKey: "mobile.iOSPairingHost.port"
    )

    /// Optional override for the name the iOS app shows for this Mac during
    /// pairing. Empty means use the Mac's name from System Settings
    /// (`Host.current().localizedName`). Useful when pairing against several
    /// Macs that would otherwise share a name.
    public let iOSPairingDisplayName = DefaultsKey<String>(
        id: "mobile.iOSPairingHost.displayName",
        defaultValue: "",
        userDefaultsKey: "mobile.iOSPairingHost.displayName"
    )

    /// Creates the Mobile settings catalog section.
    public init() {}
}
