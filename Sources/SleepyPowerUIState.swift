import Observation

/// Shared, observable power-button UI state. Sleepy Mode creates one overlay
/// window per display; injecting a single instance into every `SleepyFaceView`
/// keeps their labels in sync and makes each button compute its next action from
/// one authoritative value (instead of per-window `@State` that goes stale when
/// another display toggles).
///
/// This instance is owned by `SleepyModeController` and outlives any single
/// activation, so the lock attempt it starts is retained and cancellable here
/// rather than being an unstructured `Task` fired from a button: a lock that
/// completed after teardown would otherwise report its result onto the *next*
/// Sleepy Mode session.
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
    private(set) var isLocking = false
    /// Whether the last lock attempt found no working mechanism. Lives here
    /// rather than in each view's `@State` so all overlays report one outcome.
    private(set) var lockFailed = false

    /// The in-flight lock attempt, retained so teardown can cancel it and so a
    /// second click cannot start a competing one.
    @ObservationIgnored private var lockTask: Task<Void, Never>?

    /// Starts a lock attempt, ignoring the request when one is already running.
    ///
    /// The single start path for every Lock Mac button across every display.
    ///
    /// - Parameter power: The power service that performs the lock.
    func lockMac(using power: any SleepyPowerControlling) {
        guard lockTask == nil else { return }
        isLocking = true
        lockFailed = false
        lockTask = Task { [weak self] in
            let locked = await power.lockMacNow()
            guard let self, !Task.isCancelled else { return }
            self.lockFailed = !locked
            self.isLocking = false
            self.lockTask = nil
        }
    }

    /// Cancels any in-flight lock attempt and clears its transient state.
    ///
    /// Called on Sleepy Mode teardown so a late completion cannot surface a
    /// result belonging to a session the user has already left.
    func cancelLock() {
        lockTask?.cancel()
        lockTask = nil
        isLocking = false
        lockFailed = false
    }
}
