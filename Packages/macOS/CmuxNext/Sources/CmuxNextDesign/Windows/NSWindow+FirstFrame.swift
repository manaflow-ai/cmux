public import AppKit

extension NSWindow {
    /// Lays the window out, draws it and commits the frame now, in the caller's turn (CMUX-629). For the launch
    /// window's first frame only, once per process.
    ///
    /// `applicationDidFinishLaunching` builds the launch window in one main-thread turn. Its first frame then waited
    /// for the run loop's next before-waiting pass, which comes only once the main queue drains, and the launch
    /// queues its own work behind itself there (the agent CLI lookup, Home's page host, the daemon connection). On a
    /// fleet M4 the NIGHTLY's window was in at about 405 ms from process start and its frame committed between 605
    /// and 700 ms. This commits the frame the run loop would have committed later; nothing else changes.
    ///
    /// ```swift
    /// services.windows.restoreWhenLoaded()                                   // the launch window is in
    /// services.windows.controllers.first?.window?.commitFirstFrameNow()
    /// ```
    ///
    /// - Returns: Whether a frame was committed: false when the window is not on screen (one waiting for content).
    @discardableResult
    public func commitFirstFrameNow() -> Bool {
        guard isVisible else { return false }
        displayIfNeeded()
        // perf-gate-ok: once per launch, the launch window's first frame; the run loop would commit the same frame later.
        CATransaction.flush()
        return true
    }
}
