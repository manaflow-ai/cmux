import Foundation

/// Sleepy Mode's scene text (`SleepyMode.xcstrings`).
struct SleepyModeStrings {
    static var hint: String {
        String(localized: "sleepy.hint", defaultValue: "Keeping this Mac awake. Press any key or click to wake.", table: "SleepyMode", bundle: .localizedModule)
    }

    static var lockMac: String {
        String(localized: "sleepy.lockMac", defaultValue: "Lock Mac", table: "SleepyMode", bundle: .localizedModule)
    }

    static var noAgentsWorking: String {
        String(localized: "sleepy.noAgentsWorking", defaultValue: "No agents working", table: "SleepyMode", bundle: .localizedModule)
    }

    static func agentsWorking(_ count: Int) -> String {
        String(format: String(localized: "sleepy.agentsWorking", defaultValue: "Agents working: %lld", table: "SleepyMode", bundle: .localizedModule), count)
    }
}
