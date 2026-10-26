/// Hears the StartupScheduler's progress on the main thread. The run marker
/// is the one observer: it keeps the running task as a crash key and writes
/// that startup completed, which ends a crash streak (``StartupCrashStreak``).
@MainActor
public protocol StartupProgressObserver: AnyObject {
    /// A `.main` startup task begins. Called only before `startup_complete`;
    /// it costs one atomic store.
    func startupTaskBegan(_ name: StaticString)

    /// `startup_complete` fired, for any reason (the failsafe too).
    func startupCompleted()
}
