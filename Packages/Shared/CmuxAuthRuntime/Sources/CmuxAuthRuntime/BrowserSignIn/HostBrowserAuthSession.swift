public import Foundation

/// The terminal result of one hosted-browser auth attempt.
public enum HostBrowserAuthSessionResult: Equatable, Sendable {
    /// The hosted page redirected to the app's auth callback URL.
    case callback(URL)
    /// The user or app deliberately cancelled the browser session.
    case cancelled(reason: String)
    /// The browser session failed before returning a usable callback.
    case failed(reason: String)
}

/// One launched hosted-browser auth attempt that can be cancelled.
@MainActor
public protocol HostBrowserAuthSession: AnyObject {
    /// Start the browser session. Returns `false` when the OS refused to
    /// present it (no completion will be delivered in that case).
    func start() -> Bool
    /// Cancel the session; the completion is delivered with a cancellation
    /// error.
    func cancel()
}

/// Creates ``HostBrowserAuthSession`` attempts. Production wraps
/// `ASWebAuthenticationSession` (``ASWebBrowserAuthSessionFactory``); tests
/// inject a fake to drive the callback deterministically.
@MainActor
public protocol HostBrowserAuthSessionFactory {
    /// Make (but do not start) one browser auth attempt.
    /// - Parameters:
    ///   - signInURL: The hosted sign-in page URL.
    ///   - callbackScheme: The custom scheme the callback redirect uses.
    ///   - completion: Delivered exactly once on the main actor with the
    ///     browser session's terminal result.
    func makeSession(
        signInURL: URL,
        callbackScheme: String,
        completion: @escaping @MainActor (HostBrowserAuthSessionResult) -> Void
    ) -> any HostBrowserAuthSession
}
