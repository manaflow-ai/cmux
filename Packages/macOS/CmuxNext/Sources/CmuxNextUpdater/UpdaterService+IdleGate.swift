public import Foundation

/// Update When Idle (`updates.installWhenIdle`): the App hands the updater the question it asks Rust
/// (`UpdateIdleGate.hold`, cmux-window-rules `update_idle`), and the updater asks it only while the setting is on.
/// Live background updates (``DaemonLiveUpdates``) ask the same question before each run.
extension UpdaterService {
    /// `hold(minutes, lastInput)` answers why a staged install waits (a cmux-window-rules hold reason), nil to install.
    public func useIdleGate(_ hold: @escaping @MainActor (_ idleMinutes: Double, _ lastInput: Date?) -> String?) {
        idleInstallGate = { [weak self] in
            guard let self, let window = installWhenIdle else { return .unknown }
            return .idleHold(hold(window / .seconds(60), debugLastInput))
        }
        // Live background updates (`updates.daemon`) run only when the same rule has no hold.
        daemonLiveUpdates = DaemonLiveUpdates(bundle: .main, log: log) { [weak self] in hold($0, self?.debugLastInput) }
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
