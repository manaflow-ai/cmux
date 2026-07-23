public import AuthenticationServices
public import Foundation

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

    /// Make (but do not start) one browser auth attempt that presents from an
    /// exact window for this attempt.
    ///
    /// The default implementation preserves source compatibility for existing
    /// factories by delegating to ``makeSession(signInURL:callbackScheme:completion:)``.
    /// Factories that wrap a platform browser session should implement this
    /// overload so the supplied anchor is honored.
    func makeSession(
        signInURL: URL,
        callbackScheme: String,
        presentationAnchor: ASPresentationAnchor?,
        completion: @escaping @MainActor (HostBrowserAuthSessionResult) -> Void
    ) -> any HostBrowserAuthSession
}

/// Default compatibility behavior for factories without per-window routing.
public extension HostBrowserAuthSessionFactory {
    /// Creates an unstarted attempt by delegating to the original factory
    /// requirement when the factory does not support an exact window.
    ///
    /// - Parameters:
    ///   - signInURL: The hosted sign-in page URL.
    ///   - callbackScheme: The custom scheme used by the callback redirect.
    ///   - presentationAnchor: The requested presentation window. The default
    ///     implementation ignores this value.
    ///   - completion: The terminal result, delivered exactly once on the main
    ///     actor.
    /// - Returns: A browser-auth session that has not been started.
    func makeSession(
        signInURL: URL,
        callbackScheme: String,
        presentationAnchor: ASPresentationAnchor?,
        completion: @escaping @MainActor (HostBrowserAuthSessionResult) -> Void
    ) -> any HostBrowserAuthSession {
        makeSession(
            signInURL: signInURL,
            callbackScheme: callbackScheme,
            completion: completion
        )
    }
}
