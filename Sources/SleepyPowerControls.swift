import Foundation

/// App power-action adapter for Sleepy Mode, constructed by the composition root
/// (`SleepyModeController`) and injected into the scene. It owns no global
/// state; system effects go through an injected `SleepyCommandRunning`, and the
/// remembered pre-low-power mode lives in an injected `UserDefaults`, so the
/// behavior can be exercised with a fake runner and isolated defaults.
///
/// `@MainActor`-isolated so the Low Power restore state has one serialized
/// mutation path: every overlay window shares this single injected instance, and
/// the in-flight guard below runs synchronously on the main actor before any
/// `await`, so concurrent toggles (e.g. buttons on two displays) cannot
/// interleave the `switchedToLowThisSession` / saved-mode mutation.
@MainActor
final class SleepyPowerControls: SleepyPowerControlling {
    private let runner: SleepyCommandRunning
    private let defaults: UserDefaults
    private let previousModeKey = "sleepyMode.preLowPowerMode"
    /// True only after THIS instance switched the Mac from a non-low mode into
    /// Low Power. Gates the restore so a value left by a prior run (or a Mac that
    /// was already in Low Power) is never applied system-wide.
    private var switchedToLowThisSession = false
    /// Single-flight guard: set true synchronously before the first `await` in
    /// `setLowPowerMode`, so overlapping callers are dropped rather than racing.
    private var isMutatingLowPower = false

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
        // Drop overlapping toggles (the guard is atomic on the main actor before
        // any suspension), so the system-wide power mode has one serial owner.
        if isMutatingLowPower { return await isLowPowerOn() }
        isMutatingLowPower = true
        defer { isMutatingLowPower = false }
        let usesPowerMode = await supportsPowerMode()
        if enabled {
            if usesPowerMode {
                let current = await currentEnergyMode()
                if current != .low {
                    defaults.set(current.rawValue, forKey: previousModeKey)
                    switchedToLowThisSession = true
                }
                await runner.runPrivileged("/usr/bin/pmset", ["-a", "powermode", String(SleepyEnergyMode.low.rawValue)])
            } else {
                await runner.runPrivileged("/usr/bin/pmset", ["-a", "lowpowermode", "1"])
            }
        } else if usesPowerMode {
            // Only restore a mode we actually switched away from this session;
            // otherwise fall back to Automatic rather than a stale stored value.
            // Clear the saved value either way so it can't leak into a later run.
            var restore = SleepyEnergyMode.automatic
            if switchedToLowThisSession,
               let storedRaw = defaults.object(forKey: previousModeKey) as? Int,
               let stored = SleepyEnergyMode(rawValue: storedRaw), stored != .low {
                restore = stored
            }
            defaults.removeObject(forKey: previousModeKey)
            switchedToLowThisSession = false
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
