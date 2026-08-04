import Observation

/// Shared, observable power-button UI state. Sleepy Mode creates one overlay
/// window per display; injecting a single instance into every `SleepyFaceView`
/// keeps their labels in sync and makes each button compute its next action from
/// one authoritative value (instead of per-window `@State` that goes stale when
/// another display toggles).
@MainActor
@Observable
final class SleepyPowerUIState {
    /// Whether Low Power Mode is currently on (last re-read from the system).
    var isOn = false
    /// Whether a privileged toggle is in flight (disables the button).
    var isBusy = false
    /// Whether a lock attempt is in flight. Shared for the same reason as
    /// `isBusy`: every display shows a Lock Mac button, and overlapping clicks
    /// must not stack concurrent lock attempts whose completions race.
    var isLocking = false
    /// Whether the last lock attempt found no working mechanism. Lives here
    /// rather than in each view's `@State` so all overlays report one outcome.
    var lockFailed = false
}
