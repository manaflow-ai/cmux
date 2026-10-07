import Foundation

/// Mobile integration settings for pairing and syncing with cmux on iOS.
public struct MobileCatalogSection: SettingCatalogSection {
    /// Whether local agent notifications are forwarded to cmux on iOS.
    public let phonePushForwarding = DefaultsKey<Bool>(
        id: "mobile.phonePush.forwardingEnabled",
        defaultValue: true,
        userDefaultsKey: "forwardNotificationsToPhone"
    )

    /// When an enabled Mac forwards notifications to mobile devices.
    public let phonePushMode = DefaultsKey<String>(
        id: "mobile.phonePush.mode",
        defaultValue: "always",
        userDefaultsKey: "forwardNotificationsToPhoneMode"
    )

    /// Whether forwarded notifications omit agent and terminal content.
    public let phonePushHideContent = DefaultsKey<Bool>(
        id: "mobile.phonePush.hideContent",
        defaultValue: false,
        userDefaultsKey: "forwardNotificationsHideContent"
    )

    /// Folder paths that iOS may access after a chat or terminal references a directory.
    public let artifactFolderAccess = DefaultsKey<MobileArtifactFolderAccess>(
        id: "mobile.artifactFolderAccess",
        defaultValue: .subtree,
        userDefaultsKey: "mobile.artifactFolderAccess"
    )

    /// Whether the "On iPhone" browser may reach hosts other than this Mac's
    /// own loopback through this Mac (LAN, VPN, and internet hosts, resolved
    /// on this Mac). Off by default: the tunnel reaches only `localhost`, and
    /// the phone loads other sites over its own network. Link-local and cloud
    /// metadata addresses are refused either way (the phone loads those itself).
    public let browserTunnelAllowOtherHosts = DefaultsKey<Bool>(
        id: "mobile.browserTunnel.allowOtherHosts",
        defaultValue: false,
        userDefaultsKey: "mobile.browserTunnel.allowOtherHosts"
    )

    /// Mac-side iOS pairing and Iroh networking. Every build defaults OFF until
    /// the user explicitly enables this setting.
    public let iOSPairingHost = DefaultsKey<Bool>(
        id: "mobile.iOSPairingHost.enabled",
        defaultValue: false,
        userDefaultsKey: "mobile.iOSPairingHost.enabled"
    )

    /// Configured port for the legacy Tailscale TCP pairing listener.
    ///
    /// Iroh owns a separate UDP endpoint and chooses its own port. The TCP
    /// listener does not silently move to another port when this one is busy;
    /// its failure is reported so firewall rules and pairing routes stay
    /// truthful. A changed value applies on the next pairing start. The
    /// default mirrors `CmxMobileDefaults.defaultHostPort`, the protocol
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
