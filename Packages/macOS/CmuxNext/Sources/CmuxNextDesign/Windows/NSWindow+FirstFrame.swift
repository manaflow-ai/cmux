public import AppKit
import os

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
    /// - Parameter mark: Launch marks only (RFD 0134 Table 4 row 4, the 170 to 210 ms from ordered front to first frame).
    ///   Called with `window.display_done` after the display pass, `window.flush_done` after the flush, and `frame.loop_1` to
    ///   `frame.loop_4` at the run loop's first four before-waiting passes after this call, each run after Core Animation's own
    ///   commit observer (order 2,000,000), so each is a transaction commit that finished. The gaps between them are the
    ///   main-thread turns the frame commit queued behind. It may run on any thread.
    /// - Returns: Whether a frame was committed: false when the window is not on screen (one waiting for content).
    @discardableResult
    public func commitFirstFrameNow(mark: @escaping @Sendable (String) -> Void = { _ in }) -> Bool {
        guard isVisible else { return false }
        let passes = OSAllocatedUnfairLock(initialState: 0)  // run loop passes reported so far
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 2_000_001) { observer, _ in
            let pass = passes.withLock { count -> Int in count += 1; return count }
            mark("frame.loop_\(pass)")
            if pass >= 4, let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        displayIfNeeded()
        mark("window.display_done")
        // perf-gate-ok: once per launch, the launch window's first frame; the run loop would commit the same frame later.
        CATransaction.flush()
        mark("window.flush_done")
        return true
    }
}
