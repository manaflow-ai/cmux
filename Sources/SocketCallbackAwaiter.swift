import Foundation
import CmuxControlSocket

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
    // Refuse to block the main thread. The callbacks bridged here are delivered
    // on the main thread, so a synchronous waiter that is *itself* on the main
    // thread can only make progress by spinning a nested `CFRunLoopRun()` — that
    // froze the whole app (sidebar + every other CLI client) for the full
    // timeout (#5830). The execution policy routes every callback-waiting
    // command onto the socket worker, so arriving here on the main thread is a
    // dispatch bug; fail the single command fast (callers map nil to a timeout
    // error) instead of hanging AppKit, and never invoke `start`.
    guard !isMainThread else {
#if DEBUG
        cmuxDebugLog("socketAwaitCallback.invalidMainThread timeout=\(timeout)")
#endif
        return nil
    }

    // Synchronous socket-worker bridge: the control socket's request/response
    // contract requires this call to block its worker thread until the async
    // callback fires and then return the value to a non-async caller. That is a
    // blocking wait for a result, which actor isolation (async, non-blocking)
    // cannot express — so a semaphore is the right tool, matching the other
    // established socket-worker bridges (`v2VmCall`, the `auth.*` handlers). The
    // lock publishes `result` across the callback and waiting threads.
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
