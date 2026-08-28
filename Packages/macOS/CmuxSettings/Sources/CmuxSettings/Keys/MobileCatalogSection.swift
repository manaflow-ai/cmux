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

    /// Mac-side iOS pairing host. Release defaults OFF so macOS never asks for
    /// Local Network permission until the user opts in from Settings. DEBUG
    /// (dev) builds default ON so a dev Mac advertises its attach route without a
    /// manual Settings toggle — this is what lets a fresh dev iOS build discover
    /// the Mac automatically (see MacPairedMacBackupPublisher). An explicit user
    /// toggle still wins on either build.
    public let iOSPairingHost = DefaultsKey<Bool>(
        id: "mobile.iOSPairingHost.enabled",
        defaultValue: Self.iOSPairingHostDefault,
        userDefaultsKey: "mobile.iOSPairingHost.enabled"
    )

    #if DEBUG
    private static let iOSPairingHostDefault = true
    #else
    private static let iOSPairingHostDefault = false
    #endif

    /// Mac-side mobile relay host (the cmux Cloudflare relay). ON by default:
    /// the relay is the iPhone's default connection method, so a fresh
    /// pairing must work out of the box. Turning it off provably closes the
    /// relay WebSocket and stops all relay sessions. Every session is
    /// admitted end to end against the Mac's own signed-in account before
    /// anything is served. Independent of the Tailscale listener toggle
    /// above; the two transports never substitute for each other.
    public let relayHost = DefaultsKey<Bool>(
        id: "mobile.relayHost.enabled",
        defaultValue: true,
        userDefaultsKey: "mobile.relayHost.enabled"
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
