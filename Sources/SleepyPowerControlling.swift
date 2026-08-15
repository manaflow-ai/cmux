import Foundation

/// Power actions for the Sleepy Mode control buttons.
protocol SleepyPowerControlling: Sendable {
    /// Turns the display off now (system idle-sleep assertion still holds).
    func sleepDisplayNow() async
    /// Engages the real macOS login lock (`CGSession -suspend`).
    func lockMacNow() async
    /// Whether Low Power Mode is currently on.
    func isLowPowerOn() async -> Bool
    /// Enables/disables Low Power Mode; returns the re-read state.
    @discardableResult func setLowPowerMode(_ enabled: Bool) async -> Bool
}
