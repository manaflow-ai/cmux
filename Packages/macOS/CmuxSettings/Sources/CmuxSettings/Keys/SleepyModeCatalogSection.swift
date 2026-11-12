import Foundation

/// Typed Sleepy Mode preferences persisted in cmux.json under `sleepyMode`.
public struct SleepyModeCatalogSection: SettingCatalogSection {
    public let theme = DefaultsKey<SleepyTheme>(id: "sleepyMode.theme", defaultValue: .cmux, userDefaultsKey: "sleepyMode.theme")
    public let mascot = DefaultsKey<SleepyMascot>(id: "sleepyMode.mascot", defaultValue: .cmux, userDefaultsKey: "sleepyMode.mascot")
    public let glow = DefaultsKey<SleepyGlow>(id: "sleepyMode.glow", defaultValue: .black, userDefaultsKey: "sleepyMode.glow")
    public let showMoon = DefaultsKey<Bool>(id: "sleepyMode.showMoon", defaultValue: true, userDefaultsKey: "sleepyMode.showMoon")
    public let showStars = DefaultsKey<Bool>(id: "sleepyMode.showStars", defaultValue: true, userDefaultsKey: "sleepyMode.showStars")
    public let showZs = DefaultsKey<Bool>(id: "sleepyMode.showZs", defaultValue: true, userDefaultsKey: "sleepyMode.showZs")
    public let showClock = DefaultsKey<Bool>(id: "sleepyMode.showClock", defaultValue: true, userDefaultsKey: "sleepyMode.showClock")
    public let showStatus = DefaultsKey<Bool>(id: "sleepyMode.showStatus", defaultValue: true, userDefaultsKey: "sleepyMode.showStatus")
    public let showPets = DefaultsKey<Bool>(id: "sleepyMode.showPets", defaultValue: true, userDefaultsKey: "sleepyMode.showPets")
    public let customFace = DefaultsKey<String>(id: "sleepyMode.customFace", defaultValue: "E0EDFF", userDefaultsKey: "sleepyMode.customFace")
    public let customCap = DefaultsKey<String>(id: "sleepyMode.customCap", defaultValue: "5CD6FF", userDefaultsKey: "sleepyMode.customCap")
    public let customBlush = DefaultsKey<String>(id: "sleepyMode.customBlush", defaultValue: "FF99B5", userDefaultsKey: "sleepyMode.customBlush")
    public let customInk = DefaultsKey<String>(id: "sleepyMode.customInk", defaultValue: "333D6B", userDefaultsKey: "sleepyMode.customInk")
    public let customLogo = DefaultsKey<String>(id: "sleepyMode.customLogo", defaultValue: "6BDEFF", userDefaultsKey: "sleepyMode.customLogo")
    public let customBackground = DefaultsKey<String>(id: "sleepyMode.customBackground", defaultValue: "060812", userDefaultsKey: "sleepyMode.customBackground")
    public init() {}
}
