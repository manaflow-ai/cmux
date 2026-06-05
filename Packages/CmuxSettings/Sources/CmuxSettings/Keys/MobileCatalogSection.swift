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

    /// Creates the Mobile settings catalog section.
    public init() {}
}
