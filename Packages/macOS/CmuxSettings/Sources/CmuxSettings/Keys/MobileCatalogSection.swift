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

    /// Mac-side iOS pairing and Iroh networking. Every build defaults OFF until
    /// the user explicitly enables this setting.
    public let iOSPairingHost = DefaultsKey<Bool>(
        id: "mobile.iOSPairingHost.enabled",
        defaultValue: false,
        userDefaultsKey: "mobile.iOSPairingHost.enabled"
    )

    /// Port both Mac-side iOS listeners prefer to bind: the legacy TCP
    /// pairing listener and the Iroh endpoint's UDP socket (the port Direct
    /// addresses dial).
    ///
    /// This is a *preference*: when the port is already in use each listener
    /// independently falls back to an OS-assigned ephemeral port. The TCP
    /// listener hands the iOS app its actual bound port, and the Iroh
    /// endpoint registers its actual socket addresses with the broker, so
    /// pairing still works either way. Applying a change rebinds the TCP
    /// listener live; the Iroh endpoint adopts the new port the next time it
    /// activates (in practice, app relaunch). Configure a fixed port when you
    /// need predictable firewall rules or to avoid a conflict. The default
    /// mirrors `CmxMobileDefaults.defaultHostPort`, the protocol default
    /// mobile clients dial when a pairing payload omits a port.
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
