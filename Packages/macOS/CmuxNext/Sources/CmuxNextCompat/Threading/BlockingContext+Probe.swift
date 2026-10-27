import Dispatch

extension BlockingContext {
    /// The calling thread's context, as the blocking detector would classify a checked call made on it now; nil in a
    /// build without the detector (Release, and bench builds without `-DCMUX_BLOCKING_CHECKS`). `debug.pool_context`
    /// reports it for each kind of thread on each macOS, because the pool test reads libdispatch's queue labels,
    /// which are not API (risk 6 of plans/cmux-next/chrome-parity/p02-threads.md, task 305).
    ///
    /// - Returns: The context, or nil without the detector.
    package static func ofCallingThread() -> BlockingContext? {
        #if DEBUG || CMUX_BLOCKING_CHECKS
        current()
        #else
        nil
        #endif
    }

    /// The label of the dispatch queue the calling thread runs, the text the detector's pool test reads: a GCD root
    /// queue's (`com.apple.root.` prefix) on the cooperative pool and `DispatchQueue.global`; empty for a queue
    /// without a label.
    ///
    /// - Returns: The label.
    package static func callingQueueLabel() -> String {
        // SAFETY: dispatch_queue_get_label(NULL) returns the current queue's NUL-terminated label, which the queue
        // owns while this thread runs on it; String(cString:) copies it before the call returns.
        unsafe String(cString: __dispatch_queue_get_label(nil))
    }
}
