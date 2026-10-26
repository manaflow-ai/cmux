import CmuxNextWakeups

/// Chromium's state in the app's crash keys (p10-stability-207, ``CrashKeySlots/Key/cefState``): a crash
/// record says whether Chromium was starting, running, inside a message pump pass, shutting down or failed,
/// as Chrome's own crash keys name the browser's lifecycle (components/crash/core/common/crash_key.h).
extension CEFRuntime {
    /// Names this runtime's state in `keys` from now on (the engine the app makes passes the app's slots).
    func attachCrashKeys(_ keys: CrashKeySlots) {
        guard keys !== crashKeys else { return }
        crashKeys = keys
        noteCrashKeyState()
    }

    /// Stores ``state`` in the crash keys (each state change).
    func noteCrashKeyState() {
        crashKeys?.set(.cefState, state.crashKeyValue)
    }

    /// Quit began to close Chromium's browsers (before `CefShutdown`).
    func noteCrashKeyShuttingDown() {
        crashKeys?.set(.cefState, CrashKeySlots.CEFState.shuttingDown.rawValue)
    }

    /// One message pump pass (`CefDoMessageLoopWork`), named ``CrashKeySlots/CEFState/inPump`` while it runs; the
    /// state before it comes back after.
    func pumpWork() {
        guard let crashKeys else {
            shim?.doWork()
            return
        }
        crashKeys.withKey(.cefState, CrashKeySlots.CEFState.inPump.rawValue) { shim?.doWork() }
    }
}

extension CEFRuntime.State {
    /// The state as ``CrashKeySlots/Key/cefState`` stores it (0: Chromium never started).
    var crashKeyValue: UInt64 {
        switch self {
        case .idle: 0
        case .loading: CrashKeySlots.CEFState.initializing.rawValue
        case .ready: CrashKeySlots.CEFState.running.rawValue
        case .failed: CrashKeySlots.CEFState.failed.rawValue
        case .shutDown: CrashKeySlots.CEFState.shutDown.rawValue
        }
    }
}
