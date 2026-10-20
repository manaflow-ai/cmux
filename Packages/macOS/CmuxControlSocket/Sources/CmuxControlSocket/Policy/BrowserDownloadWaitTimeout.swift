public import Foundation

/// Shared timeout window for the `browser.download.wait` control call.
///
/// The app-side handler and the command-line client have to agree: the client
/// has to outwait the window the handler is allowed to spend, or a download
/// that the app reports on time still fails in the terminal. Both sides read
/// ``standard`` so the two windows cannot drift apart.
///
/// The windows are values rather than fixed constants so a test can hold the
/// same agreement at a fraction of the wall-clock cost instead of waiting the
/// shipped window out.
public struct BrowserDownloadWaitTimeout: Equatable, Sendable {
    /// The windows the app and the CLI ship with.
    public static let standard = BrowserDownloadWaitTimeout()

    /// Window the handler waits when the caller sends no `timeout_ms`.
    public let defaultTimeoutMilliseconds: Int

    /// Ceiling the handler applies to a caller-supplied `timeout_ms`.
    public let maximumTimeoutMilliseconds: Int

    /// Slack the client adds on top of the handler's window to cover request
    /// dispatch, the handler's own bookkeeping, and the reply hop.
    public let clientResponseSlackSeconds: TimeInterval

    /// Creates a window pair the handler and the client both read.
    ///
    /// - Parameters:
    ///   - defaultTimeoutMilliseconds: Window for a caller that sends no
    ///     `timeout_ms`.
    ///   - maximumTimeoutMilliseconds: Ceiling for a caller-supplied
    ///     `timeout_ms`.
    ///   - clientResponseSlackSeconds: Slack the client adds to the handler's
    ///     window.
    public init(
        defaultTimeoutMilliseconds: Int = 10_000,
        maximumTimeoutMilliseconds: Int = 120_000,
        clientResponseSlackSeconds: TimeInterval = 5
    ) {
        self.defaultTimeoutMilliseconds = defaultTimeoutMilliseconds
        self.maximumTimeoutMilliseconds = maximumTimeoutMilliseconds
        self.clientResponseSlackSeconds = clientResponseSlackSeconds
    }

    /// Window the handler spends for `requestedMilliseconds`.
    ///
    /// - Parameter requestedMilliseconds: The caller's `timeout_ms`, or `nil`
    ///   when the caller sent none.
    /// - Returns: The clamped handler window in milliseconds.
    public func handlerTimeoutMilliseconds(
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
    public func clientResponseTimeoutSeconds(
        requestedMilliseconds: Int?
    ) -> TimeInterval {
        let handlerWindow = handlerTimeoutMilliseconds(
            requestedMilliseconds: requestedMilliseconds
        )
        return TimeInterval(handlerWindow) / 1000.0 + clientResponseSlackSeconds
    }
}
