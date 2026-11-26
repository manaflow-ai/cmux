public import Foundation

/// Update When Idle (`updates.installWhenIdle`): the App hands the updater the question it asks Rust
/// (`UpdateIdleGate.hold`, cmux-window-rules `update_idle`), and the updater asks it only while the setting is on.
extension UpdaterService {
    /// `hold(minutes, lastInput, declined, sinceDecline)` answers why a staged install waits (a cmux-window-rules
    /// hold reason, nil to install) and, when it installs, the away reading it acted on. `nextCheck(sinceLast,
    /// interval)` is Settings > Updates' Next Check rule (seconds from now, nil when automatic checks are off).
    public func useIdleGate(_ hold: @escaping @MainActor (_ idleMinutes: Double, _ lastInput: Date?, _ declined: Int,
                                                          _ sinceDecline: Double?) -> (hold: String?, away: String?),
                            nextCheck: @escaping @MainActor (_ secondsSinceLastCheck: Double?, _ intervalSeconds: Double) -> Double?) {
        nextCheckRule = nextCheck
        idleInstallGate = { [weak self] in
            guard let self, let window = installWhenIdle else { return .unknown }
            let answer = hold(window / .seconds(60), debugLastInput, idleDeclinedInstalls, idleDeclinedAt.map { Date().timeIntervalSince($0) })
            if answer.hold == nil { idleAwayReading = answer.away }
            return .idleHold(answer.hold)
        }
    }

    /// `debug.updater {action: "input"}`: input "now" for Update When Idle, or `clear` for the real input time again
    /// (the update-idle harness, scripts/cmux-next/update-harness/idle_e2e.py: a fleet Mac has no person). DEV and
    /// bench builds only; a shipping build answers and changes nothing.
    public func debugInput(clear: Bool) -> [String: Bool] {
        #if DEBUG || CMUX_BENCH_HOOKS
        debugLastInput = clear ? nil : Date()
        #endif
        return ["debugInput": debugLastInput != nil]
    }
}
