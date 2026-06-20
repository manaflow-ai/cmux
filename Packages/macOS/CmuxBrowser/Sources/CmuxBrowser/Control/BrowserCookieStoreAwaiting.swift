public import Foundation

/// A seam that runs a bounded, synchronous blocking-await over an async callback.
///
/// ``BrowserCookieRepository`` reaches a `WKHTTPCookieStore` through callback-based
/// WebKit APIs (`getAllCookies`, `setCookie`, `delete`) that have no `async`
/// overload usable from the synchronous control-command lane, so it blocks the
/// calling thread until the callback fires (or a timeout elapses). The blocking
/// primitive itself is pure Foundation run-loop / dispatch plumbing with no
/// WebKit, main-actor, or per-surface reach, so it lives in a higher package and
/// is injected here behind this seam rather than duplicated.
///
/// The production conformer is `CmuxControlSocket.ControlBrowserEvalAwaiter`, the
/// same primitive the worker-lane browser JS-eval paths block on, so the cookie
/// store I/O and the JS-eval I/O share one await implementation.
///
/// ## Isolation
///
/// `Sendable`, NOT `@MainActor`. ``await(timeout:start:)`` runs on the calling
/// thread and is expected to service a main-actor-hopping callback (the
/// `WKHTTPCookieStore` callbacks hop to the main actor) while it blocks, exactly
/// as the legacy `v2AwaitCallback` did.
public protocol BrowserCookieStoreAwaiting: Sendable {
    /// Starts an async callback and blocks the calling thread until it fires or
    /// `timeout` elapses.
    ///
    /// - Parameters:
    ///   - timeout: The maximum time to wait, in seconds.
    ///   - start: A closure that receives a `finish` continuation; the conformer
    ///     calls it once with the resolved value. `finish` must be safe to call
    ///     from any thread and idempotent (later calls ignored).
    /// - Returns: The delivered value, or `nil` if the timeout elapsed first.
    func await<T>(
        timeout: TimeInterval,
        start: (@escaping @Sendable (T) -> Void) -> Void
    ) -> T?
}
