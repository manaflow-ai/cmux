import Foundation

/// UserDefaults keys for `SleepyModeSettingsStore`. A `struct` of static keys
/// (not a caseless namespace `enum`) per the cmux package-design policy.
struct SleepyModeDefaultsKeys {
    static let theme = "sleepyMode.theme"
    static let mascot = "sleepyMode.mascot"
    static let glow = "sleepyMode.glow"
    static let showMoon = "sleepyMode.showMoon"
    static let showStars = "sleepyMode.showStars"
    static let showZs = "sleepyMode.showZs"
    static let showClock = "sleepyMode.showClock"
    static let showStatus = "sleepyMode.showStatus"
    static let showPets = "sleepyMode.showPets"
    static let customFace = "sleepyMode.customFace"
    static let customCap = "sleepyMode.customCap"
    static let customBlush = "sleepyMode.customBlush"
    static let customInk = "sleepyMode.customInk"
    static let customLogo = "sleepyMode.customLogo"
    static let customBackground = "sleepyMode.customBackground"

    private init() {}
}
