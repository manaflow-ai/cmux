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
        let started = MainThreadEngineStart.shared.run(body)
        firstWindowRequested = started == 1
        firstWindowPending = started == 1
        return started
    }

    /// A window exists (OnAfterCreated for a create_window request, also one
    /// whose tab closed meanwhile).
    func firstWindowEnded() { firstWindowPending = false }

    /// One run of the external message pump. `windowPending`: a
    /// create_window request still waits for its window; when none does
    /// (its creation ended without OnAfterCreated: a crash, shutdown) the
    /// first window's step ends too.
    func pump(windowPending: Bool, _ work: () -> Void) {
        if !windowPending { firstWindowPending = false }
        if firstWindowPending { MainThreadEngineStart.shared.run(work) } else { work() }
    }
}
