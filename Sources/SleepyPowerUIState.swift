import Observation

/// Shared, observable Low Power UI state. Sleepy Mode creates one overlay window
/// per display; injecting a single instance into every `SleepyFaceView` keeps
/// their labels in sync and makes each button compute its next action from one
/// authoritative value (instead of per-window `@State` that goes stale when
/// another display toggles).
@MainActor
@Observable
final class SleepyPowerUIState {
    /// Whether Low Power Mode is currently on (last re-read from the system).
    var isOn = false
    /// Whether a privileged toggle is in flight (disables the button).
    var isBusy = false
    /// True after a Lock Mac attempt reported no lock mechanism was available,
    /// so the overlay tells the user instead of silently staying unlocked
    /// (the failure mode of https://github.com/manaflow-ai/cmux/issues/9730).
    /// Cleared by a later successful lock.
    var lockFailed = false
}
