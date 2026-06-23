import Foundation

/// Mobile integration settings for pairing and syncing with cmux on iOS.
public struct MobileCatalogSection: SettingCatalogSection {
    /// Mac-side iOS pairing host. Defaults off so macOS never asks for Local
    /// Network permission until the user opts in from Settings.
    public let iOSPairingHost = DefaultsKey<Bool>(
        id: "mobile.iOSPairingHost.enabled",
        defaultValue: false,
        userDefaultsKey: "mobile.iOSPairingHost.enabled"
    )

    /// Mac-side iroh accept lane (plans/feat-ios-iroh/DESIGN.md). When on, the
    /// Mac binds an iroh endpoint and advertises a dial-by-EndpointId route, so
    /// signed-in phones attach without Tailscale or a LAN. Defaults off until the
    /// on-device cellular attach is validated; the design flips this on by
    /// default as the post-dogfood step.
    public let iOSIrohHost = DefaultsKey<Bool>(
        id: "mobile.iOSIrohHost.enabled",
        defaultValue: false,
        userDefaultsKey: "mobile.iOSIrohHost.enabled"
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
