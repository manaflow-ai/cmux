import Foundation

/// Independent discovery, incoming-access, and sidebar visibility preferences.
public struct DevicesCatalogSection: SettingCatalogSection {
    /// Discovers the account's other Macs independently of incoming access.
    public let discoveryEnabled = DefaultsKey<Bool>(
        id: "devices.discovery.enabled",
        defaultValue: true,
        userDefaultsKey: "devices.discovery.enabled"
    )

    /// Allows this Mac to advertise and accept remote sessions from the account's devices.
    public let incomingAccessEnabled = DefaultsKey<Bool>(
        id: "devices.incomingAccess.enabled",
        defaultValue: true,
        userDefaultsKey: "devices.incomingAccess.enabled"
    )

    /// Physical Mac identifiers hidden from My Devices on this installation.
    /// Hiding changes presentation; it does not revoke pairing or close existing panes.
    public let hiddenMacIDs = DefaultsKey<[String]>(
        id: "devices.sidebar.hiddenMacIDs",
        defaultValue: [],
        userDefaultsKey: "devices.sidebar.hiddenMacIDs"
    )

    /// Creates the device preferences catalog.
    public init() {}
}
