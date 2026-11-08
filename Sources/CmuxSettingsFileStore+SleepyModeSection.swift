import CmuxSettings
import Foundation

extension CmuxSettingsFileStore {
    func parseSleepyModeSection(
        _ section: [String: Any],
        sourcePath: String,
        snapshot: inout ResolvedSettingsSnapshot
    ) {
        let catalog = SleepyModeCatalogSection()
        let enumValues: [(String, Set<String>, String)] = [
            ("theme", Set(SleepyTheme.allCases.map(\.rawValue)), catalog.theme.userDefaultsKey),
            ("mascot", Set(SleepyMascot.allCases.map(\.rawValue)), catalog.mascot.userDefaultsKey),
            ("glow", Set(SleepyGlow.allCases.map(\.rawValue)), catalog.glow.userDefaultsKey)
        ]
        for (name, allowed, defaultsKey) in enumValues where section.keys.contains(name) {
            guard let raw = jsonString(section[name]), allowed.contains(raw) else {
                logInvalid("sleepyMode.\(name)", sourcePath: sourcePath)
                continue
            }
            snapshot.managedUserDefaults[defaultsKey] = .string(raw)
        }
        let booleans: [(String, String)] = [
            ("showMoon", catalog.showMoon.userDefaultsKey), ("showStars", catalog.showStars.userDefaultsKey),
            ("showZs", catalog.showZs.userDefaultsKey), ("showClock", catalog.showClock.userDefaultsKey),
            ("showStatus", catalog.showStatus.userDefaultsKey), ("showPets", catalog.showPets.userDefaultsKey)
        ]
        for (name, defaultsKey) in booleans where section.keys.contains(name) {
            guard let value = jsonBool(section[name]) else {
                logInvalid("sleepyMode.\(name)", sourcePath: sourcePath)
                continue
            }
            snapshot.managedUserDefaults[defaultsKey] = .bool(value)
        }
        let colors: [(String, String)] = [
            ("customFace", catalog.customFace.userDefaultsKey), ("customCap", catalog.customCap.userDefaultsKey),
            ("customBlush", catalog.customBlush.userDefaultsKey), ("customInk", catalog.customInk.userDefaultsKey),
            ("customLogo", catalog.customLogo.userDefaultsKey), ("customBackground", catalog.customBackground.userDefaultsKey)
        ]
        for (name, defaultsKey) in colors where section.keys.contains(name) {
            guard let raw = jsonString(section[name]), raw.count == 6,
                  raw.allSatisfy({ $0.isHexDigit }) else {
                logInvalid("sleepyMode.\(name)", sourcePath: sourcePath)
                continue
            }
            snapshot.managedUserDefaults[defaultsKey] = .string(raw.uppercased())
        }
    }
}
