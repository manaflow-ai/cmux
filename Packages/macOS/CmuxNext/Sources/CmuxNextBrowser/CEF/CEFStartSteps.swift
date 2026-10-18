import CmuxNextCompat

/// The main-thread steps of Chromium's start, counted as
/// `MainThreadEngineStart` time so control deadlines skip them:
/// `CefInitialize`, and Chromium's work from the first `create_window` until
/// that window exists (or its creation fails). Chromium builds its first
/// browser window in that work: in a macOS 26 VM the window alone held the
/// main thread for about 0.8 s, after a CefInitialize of about 0.8 s, and an
/// `action.run` that opened the first Chromium tab missed its 2 s deadline
/// although nothing it waited for was slow (os-smoke, 2026-10-18).
final class CEFStartSteps {
    static let shared = CEFStartSteps()

    /// True from the first `create_window` until that window exists or
    /// fails; false again after.
    private(set) var firstWindowPending = false
    private var firstWindowRequested = false

    /// `CefInitialize` (main thread).
    func initialize<E: Error>(_ body: () throws(E) -> Void) throws(E) {
        try MainThreadEngineStart.shared.run(body)
    }

    /// The first browser window's `create_window` call.
    func createWindow(_ body: () -> Int32) -> Int32 {
        guard !firstWindowRequested else { return body() }
        firstWindowRequested = true
        firstWindowPending = true
        let started = MainThreadEngineStart.shared.run(body)
        if started != 1 { firstWindowPending = false }
        return started
    }

    /// The first window exists (OnAfterCreated) or its creation failed.
    func firstWindowEnded() { firstWindowPending = false }

    /// One run of the external message pump.
    func pump(_ work: () -> Void) {
        if firstWindowPending { MainThreadEngineStart.shared.run(work) } else { work() }
    }
}
