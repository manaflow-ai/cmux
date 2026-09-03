import Foundation

/// Power actions for the Sleepy Mode control buttons.
protocol SleepyPowerControlling: Sendable {
    /// Turns the display off now (system idle-sleep assertion still holds).
    func sleepDisplayNow() async
    /// Engages the real macOS login lock; returns only after the system confirms
    /// the transition or the bounded confirmation deadline is reached. An
    /// unconfirmed request is canceled with its Sleepy Mode lifecycle rather
    /// than reported as a successful lock.
    @discardableResult func lockMacNow() async -> Bool
    /// Same operation with lifecycle cancellation serialized against the
    /// irreversible loginwindow invocation.
    @discardableResult func lockMacNow(using gate: SleepyLockInvocationGate) async -> Bool
    /// Whether Low Power Mode is currently on.
    func isLowPowerOn() async -> Bool
    /// Enables/disables Low Power Mode; returns the re-read state.
    @discardableResult func setLowPowerMode(_ enabled: Bool) async -> Bool
}

extension SleepyPowerControlling {
    @discardableResult
    func lockMacNow(using gate: SleepyLockInvocationGate) async -> Bool {
        guard gate.invoke({}) else { return false }
        return await lockMacNow()
    }
}
