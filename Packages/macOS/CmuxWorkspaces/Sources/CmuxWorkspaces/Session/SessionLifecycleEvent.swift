/// A macOS workspace-lifecycle signal the app reacts to for session-snapshot
/// persistence and socket-listener recovery.
///
/// These are the three `NSWorkspace.shared.notificationCenter` notifications the
/// legacy `AppDelegate.installLifecycleSnapshotObserversIfNeeded()` registered
/// for, re-expressed as a typed `Sendable` value so the observer mechanism can
/// live in ``SessionLifecycleObserver`` and reach the app through an
/// `AsyncStream` instead of three raw `NotificationCenter` closures. Each case
/// maps one-for-one to a legacy observer; the app's reaction to each (which
/// reads live window/tab state and writes the snapshot file, or restarts the
/// control socket) stays app-side, driven by the stream.
public enum SessionLifecycleEvent: Sendable {
    /// The system is powering off or restarting
    /// (`NSWorkspace.willPowerOffNotification`). The app writes a final
    /// scrollback-including snapshot and flushes closed-item history.
    case willPowerOff

    /// The login session resigned active, e.g. fast user switching or screen
    /// lock (`NSWorkspace.sessionDidResignActiveNotification`). The app saves a
    /// snapshot, branching on whether termination is already underway.
    case sessionDidResignActive

    /// The machine woke from sleep (`NSWorkspace.didWakeNotification`). The app
    /// restarts the control-socket listener if it is enabled.
    case didWake
}
