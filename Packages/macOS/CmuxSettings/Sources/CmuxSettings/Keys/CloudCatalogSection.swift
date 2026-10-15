import Foundation

/// Cloud machine preferences stored on this Mac (the `cloud.*` keys that are
/// not beta flags).
public struct CloudCatalogSection: SettingCatalogSection {
    /// Whether Cloud Secrets are delivered automatically: to a machine when it
    /// is created, and to every machine already synced when a secret changes.
    /// Defaults on; while off, secrets reach a machine only through an explicit
    /// sync (`cmux vm secrets sync`, the sheet's Sync now) or `cmux vm agent`.
    public let secretsAutoSync = DefaultsKey<Bool>(
        id: "cloud.secrets.autoSync",
        defaultValue: true,
        userDefaultsKey: "cloud.secrets.autoSync"
    )

    /// Creates the Cloud preferences catalog.
    public init() {}
}
