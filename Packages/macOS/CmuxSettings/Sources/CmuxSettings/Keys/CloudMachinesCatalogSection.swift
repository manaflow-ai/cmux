import Foundation

/// Cloud Machines settings: what the user's Cloud VMs may do to this Mac.
public struct CloudMachinesCatalogSection: SettingCatalogSection {
    /// Let Cloud VMs send notifications, titles, and agent status to this Mac
    /// over the private Cloud VM network. Off by default. While on, the app
    /// listens on its own tunnel addresses only, and only while the account
    /// owns at least one machine; machines receive a per-machine token the
    /// Mac minted, and only the notification and telemetry verbs are admitted.
    public let hostNotifications = DefaultsKey<Bool>(
        id: "cloud.vmHostNotifications.enabled",
        defaultValue: false,
        userDefaultsKey: "cloud.vmHostNotifications.enabled"
    )

    public init() {}
}
