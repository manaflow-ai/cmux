import Foundation

/// App power-action adapter for Sleepy Mode, constructed by the composition root
/// (`SleepyModeController`) and injected into the scene. It owns no global
/// state; system effects go through an injected `SleepyCommandRunning`, and the
/// remembered pre-low-power mode lives in an injected `UserDefaults`, so the
/// behavior can be exercised with a fake runner and isolated defaults.
final class SleepyPowerControls: SleepyPowerControlling {
    private let runner: SleepyCommandRunning
    private let defaults: UserDefaults
    private let previousModeKey = "sleepyMode.preLowPowerMode"

    init(runner: SleepyCommandRunning = SystemCommandRunner(), defaults: UserDefaults = .standard) {
        self.runner = runner
        self.defaults = defaults
    }

    /// Turns the display off now (the system idle-sleep assertion still holds, so
    /// this is an explicit manual sleep, not idle sleep).
    func sleepDisplayNow() async {
        await runner.run("/usr/bin/pmset", ["displaysleepnow"])
    }

    /// Engages the real macOS login lock via the supported `CGSession -suspend`
    /// mechanism (returning to the session requires the account password /
    /// Touch ID) — Apple's loginwindow, not our overlay, and no private symbol.
    func lockMacNow() async {
        await runner.run("/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession", ["-suspend"])
    }

    func isLowPowerOn() async -> Bool {
        await currentEnergyMode() == .low
    }

    /// Enables/disables Low Power Mode. On 3-mode Macs, enabling remembers the
    /// mode you were on and disabling restores it; on binary Macs it toggles
    /// `lowpowermode`. Returns the re-read state after the change applies.
    @discardableResult
    func setLowPowerMode(_ enabled: Bool) async -> Bool {
        let usesPowerMode = await supportsPowerMode()
        if enabled {
            if usesPowerMode {
                let current = await currentEnergyMode()
                if current != .low { defaults.set(current.rawValue, forKey: previousModeKey) }
                await runner.runPrivileged("/usr/bin/pmset", ["-a", "powermode", String(SleepyEnergyMode.low.rawValue)])
            } else {
                await runner.runPrivileged("/usr/bin/pmset", ["-a", "lowpowermode", "1"])
            }
        } else if usesPowerMode {
            let storedRaw = defaults.object(forKey: previousModeKey) as? Int ?? SleepyEnergyMode.automatic.rawValue
            var restore = SleepyEnergyMode(rawValue: storedRaw) ?? .automatic
            if restore == .low { restore = .automatic }
            await runner.runPrivileged("/usr/bin/pmset", ["-a", "powermode", String(restore.rawValue)])
        } else {
            await runner.runPrivileged("/usr/bin/pmset", ["-a", "lowpowermode", "0"])
        }
        return await isLowPowerOn()
    }

    private func currentEnergyMode() async -> SleepyEnergyMode {
        guard let out = await runner.capture("/usr/bin/pmset", ["-g"]) else { return .automatic }
        for rawLine in out.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("powermode"),
               let value = line.split(separator: " ").compactMap({ Int($0) }).first,
               let mode = SleepyEnergyMode(rawValue: value) {
                return mode
            }
        }
        for rawLine in out.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("lowpowermode") {
                return line.split(separator: " ").compactMap({ Int($0) }).first == 1 ? .low : .automatic
            }
        }
        return .automatic
    }

    /// True on Macs exposing the 3-way `powermode`; matches a line whose key is
    /// exactly `powermode`, not the `lowpowermode` substring.
    private func supportsPowerMode() async -> Bool {
        guard let out = await runner.capture("/usr/bin/pmset", ["-g"]) else { return false }
        for rawLine in out.split(separator: "\n") where rawLine.trimmingCharacters(in: .whitespaces).hasPrefix("powermode") {
            return true
        }
        return false
    }
}
