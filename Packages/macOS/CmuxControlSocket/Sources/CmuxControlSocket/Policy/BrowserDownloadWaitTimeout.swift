public import Foundation

/// Shared timeout window for the `browser.download.wait` control call.
///
/// The app-side handler and the command-line client have to agree: the client
/// has to outwait the window the handler is allowed to spend, or a download
/// that the app reports on time still fails in the terminal. Both sides read
/// the numbers here so the two windows cannot drift apart.
public enum BrowserDownloadWaitTimeout {
    /// Window the handler waits when the caller sends no `timeout_ms`.
    public static let defaultTimeoutMilliseconds = 10_000

    /// Ceiling the handler applies to a caller-supplied `timeout_ms`.
    public static let maximumTimeoutMilliseconds = 120_000

    /// Slack the client adds on top of the handler's window to cover request
    /// dispatch, the handler's own bookkeeping, and the reply hop.
    public static let clientResponseSlackSeconds: TimeInterval = 5

    /// Window the handler spends for `requestedMilliseconds`.
    ///
    /// - Parameter requestedMilliseconds: The caller's `timeout_ms`, or `nil`
    ///   when the caller sent none.
    /// - Returns: The clamped handler window in milliseconds.
    public static func handlerTimeoutMilliseconds(
        requestedMilliseconds: Int?
    ) -> Int {
        let requested = max(1, requestedMilliseconds ?? defaultTimeoutMilliseconds)
        return min(requested, maximumTimeoutMilliseconds)
    }

    /// Socket response timeout the client uses for `requestedMilliseconds`.
    ///
    /// - Parameter requestedMilliseconds: The caller's `--timeout-ms`, or `nil`
    ///   when the caller passed none.
    /// - Returns: The handler window plus ``clientResponseSlackSeconds``.
    public static func clientResponseTimeoutSeconds(
        requestedMilliseconds: Int?
    ) -> TimeInterval {
        let handlerWindow = handlerTimeoutMilliseconds(
            requestedMilliseconds: requestedMilliseconds
        )
        return TimeInterval(handlerWindow) / 1000.0 + clientResponseSlackSeconds
    }
}
