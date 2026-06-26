import Foundation

/// Synchronously waits for the callback delivered by `start`, up to `timeout`
/// seconds, returning `nil` on timeout. The shared blocking-wait primitive for
/// control-socket command handlers that bridge an async callback (WKWebView
/// JavaScript results, screenshot capture, cookie-store reads) into a
/// synchronous socket reply.
///
/// This MUST run off the main thread. The control-command execution policy
/// (`ControlCommandExecutionPolicy`) routes every callback-waiting command onto
/// the socket-worker thread for exactly this reason. Parking the **main thread**
/// here freezes the whole app — the sidebar plus every other CLI client
/// serialize behind it — for the full command timeout, which was the #5830
/// whole-app freeze (a `browser eval`/`screenshot` callback waited on inside a
/// nested `CFRunLoopRun()` on the main thread).
///
/// - Parameters:
///   - timeout: Maximum seconds to wait for the callback before giving up.
///   - isMainThread: Whether the calling thread is the main thread. Injected so
///     the main-thread dispatch contract can be exercised deterministically in
///     tests; defaults to the live `Thread.isMainThread`.
///   - start: Begins the async work, invoking the supplied escaping completion
///     with the result when it finishes.
func socketAwaitCallback<T>(
    timeout: TimeInterval,
    isMainThread: Bool = Thread.isMainThread,
    start: (@escaping (T) -> Void) -> Void
) -> T? {
    if isMainThread {
        let runLoop = CFRunLoopGetCurrent()
        let lock = NSLock()
        var resolved = false
        var timedOut = false
        var result: T?

        let finish: (T) -> Void = { value in
            lock.lock()
            guard !resolved else {
                lock.unlock()
                return
            }
            resolved = true
            result = value
            lock.unlock()
            CFRunLoopStop(runLoop)
        }

        guard let timeoutTimer = CFRunLoopTimerCreateWithHandler(
            kCFAllocatorDefault,
            CFAbsoluteTimeGetCurrent() + timeout,
            0,
            0,
            0,
            { _ in
                lock.lock()
                if !resolved {
                    resolved = true
                    timedOut = true
                }
                lock.unlock()
                CFRunLoopStop(runLoop)
            }
        ) else {
            return nil
        }
        CFRunLoopAddTimer(runLoop, timeoutTimer, .defaultMode)
        defer { CFRunLoopTimerInvalidate(timeoutTimer) }

        start(finish)
        while true {
            lock.lock()
            if resolved {
                let value = result
                let didTimeOut = timedOut
                lock.unlock()
                return didTimeOut ? nil : value
            }
            lock.unlock()

            CFRunLoopRun()
        }
    }

    let semaphore = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var result: T?
    start { value in
        lock.lock()
        result = value
        lock.unlock()
        semaphore.signal()
    }
    guard semaphore.wait(timeout: .now() + timeout) == .success else {
        return nil
    }
    lock.lock()
    defer { lock.unlock() }
    return result
}
