import CmuxNextTrace
import CmuxNextWakeups

/// Chromium's state in the app's crash keys (``CrashKeySlots/Key/cefState``): a crash
/// record says whether Chromium was starting, running, inside a message pump pass (``CEFMessagePump`` sets that
/// one), shutting down or failed, as Chrome's own crash keys name the browser's lifecycle
/// (components/crash/core/common/crash_key.h).
extension CEFRuntime {
    /// Names this runtime's state in `keys` from now on (the engine the app makes passes the app's slots).
    func attachCrashKeys(_ keys: CrashKeySlots) {
        guard keys !== crashKeys else { return }
        crashKeys = keys
        noteCrashKeyState()
    }

    /// Stores ``state`` in the crash keys (each state change), and the fork's API version once Chromium is ready.
    func noteCrashKeyState() {
        crashKeys?.noteCEF(state, forkAPIVersion: forkAPIVersion)
    }

    /// Quit began to close Chromium's browsers (before `CefShutdown`).
    func noteCrashKeyShuttingDown() {
        crashKeys?.set(.cefState, CrashKeySlots.CEFState.shuttingDown.rawValue)
    }
}

extension CrashKeySlots {
    /// Names Chromium's `state` in ``Key/cefState`` and, when it is ready, the cmux fork's API version in the
    /// crash-key page's ``CrashKeySlot/cefAPIVersion``: a report says which Chromium the
    /// app ran. The version stays after a later failure or shutdown.
    func noteCEF(_ state: CEFRuntime.State, forkAPIVersion: @autoclosure () -> Int32) {
        set(.cefState, state.crashKeyValue)
        guard state == .ready else { return }
        page.set(.cefAPIVersion, UInt64(clamping: forkAPIVersion()))
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
