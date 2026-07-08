import Foundation

/// Power management settings for keeping the Mac reachable during work.
public struct PowerCatalogSection: SettingCatalogSection {
    /// Keeps the Mac from idle system sleep while cmux observes running agent sessions.
    public let preventSleepWhileAgentsRunning = DefaultsKey<Bool>(
        id: "power.preventSleepWhileAgentsRunning.enabled",
        defaultValue: false,
        userDefaultsKey: "power.preventSleepWhileAgentsRunning.enabled"
    )

    /// Keeps the Mac from idle system sleep while an iPhone or iPad is connected.
    public let preventSleepWhileMobileConnected = DefaultsKey<Bool>(
        id: "power.preventSleepWhileMobileConnected.enabled",
        defaultValue: true,
        userDefaultsKey: "power.preventSleepWhileMobileConnected.enabled"
    )

    /// Creates the Power settings catalog section.
    public init() {}
}
