import Foundation

/// Mobile integration settings for pairing and syncing with cmux on iOS.
public struct MobileCatalogSection: SettingCatalogSection {
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
