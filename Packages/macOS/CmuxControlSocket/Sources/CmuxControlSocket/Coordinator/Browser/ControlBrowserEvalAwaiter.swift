public import Foundation

/// The synchronous, bounded blocking-await primitive the worker-lane browser
/// JS-eval core is built on, lifted byte-faithfully from the former
/// `TerminalController.v2AwaitCallback`.
///
/// Every blocking step the socket-worker browser methods take (the
/// `WKWebView` evaluate/`callAsyncJavaScript` round-trip in `v2RunJavaScript`,
/// the document-load KVO kick in `v2EnsureBrowserDocumentLoaded`, the
/// screenshot capture, the download wait) bottoms out here: it starts an
/// async callback and blocks the caller until the callback fires or the timeout
/// elapses, returning the delivered value (or `nil` on timeout).
///
/// ## Why a value type, not a worker behind a seam
///
/// Unlike ``ControlBrowserNavigationWorker`` / ``ControlBrowserQueryWorker``,
/// this primitive has no app reach: it touches no `WebKit`, no main actor, and
/// no per-surface mutable state. It is pure Foundation run-loop / dispatch
/// plumbing, so it lifts wholesale into the package as a `Sendable` value the
/// app-side eval core calls directly, with no inverted `*Reading` seam.
///
/// ## Isolation
///
/// `Sendable`, NOT `@MainActor`. ``await(timeout:start:)`` runs on the calling
/// thread and branches on `Thread.isMainThread`, exactly as the legacy body
/// did:
/// - On the main thread it drives a nested `CFRunLoop` with a one-shot timeout
///   timer so the awaited callback (which itself hops to the main actor to touch
///   `WKWebView`) can still be serviced while this call blocks. The
///   `CFRunLoopStop` from either `finish` or the timer breaks the inner
///   `CFRunLoopRun`, and the `resolved`/`timedOut` flags (guarded by the
///   `NSLock`) decide the return so a late callback after a timeout is ignored.
/// - Off the main thread it blocks on a `DispatchSemaphore` with the same
///   timeout, reading the delivered value under the lock.
public struct ControlBrowserEvalAwaiter: Sendable {
    /// Creates an awaiter. Stateless; one instance can serve every call.
    public init() {}

    /// Starts an async callback and blocks the calling thread until it fires or
    /// `timeout` elapses.
    ///
    /// Byte-faithful to the legacy `v2AwaitCallback`: the main-thread branch
    /// pumps a nested `CFRunLoop` (so a main-actor-hopping callback can be
    /// delivered while this call blocks); the off-main branch waits on a
    /// `DispatchSemaphore`. A callback delivered after the timeout has fired is
    /// discarded.
    ///
    /// - Parameters:
    ///   - timeout: The maximum time to wait, in seconds.
    ///   - start: A closure that receives a `finish` continuation; call it once
    ///     with the resolved value. `finish` is safe to call from any thread and
    ///     is idempotent (later calls are ignored).
    /// - Returns: The delivered value, or `nil` if the timeout elapsed first.
    public func await<T>(
        timeout: TimeInterval,
        start: (@escaping (T) -> Void) -> Void
    ) -> T? {
        if Thread.isMainThread {
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
}
