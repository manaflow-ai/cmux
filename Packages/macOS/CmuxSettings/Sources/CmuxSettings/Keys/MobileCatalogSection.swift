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

    /// Every build requires explicit pairing opt-in before any IROH activity.
    public let iOSPairingHost = DefaultsKey<Bool>(
        id: "mobile.iOSPairingHost.enabled",
        defaultValue: false,
        userDefaultsKey: "mobile.iOSPairingHost.enabled"
    )

    /// Preferred IROH UDP port. A saved change applies at the next pairing
    /// start. The runtime reports its actual port locally and falls back to
    /// an available port if necessary; local addresses never go to the server.
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
