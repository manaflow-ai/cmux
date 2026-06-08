import Foundation

/// A reporting seam the ``AuthCoordinator`` calls when a sign-in flow fails,
/// before the underlying error is wrapped into a display-safe ``AuthError``.
///
/// `CmuxAuthRuntime` is a shared, low-level package that links into both the
/// macOS and iOS apps. iOS links no crash/error reporter and the package may
/// not depend on a concrete telemetry SDK, so the real reporter is injected at
/// each app's composition root: macOS passes a Sentry-backed conformer, iOS a
/// diagnostics-log-backed one (or the ``NoopAuthErrorReporting`` default).
///
/// Without this seam, OAuth/Apple sign-in failures were swallowed into the
/// generic "Something went wrong. Please try again." message and never reached
/// any backend, leaving production auth breaks invisible.
public protocol AuthErrorReporting: Sendable {
    /// Report a sign-in failure with the underlying error and structured
    /// context, for capture by the app's telemetry/diagnostics backend.
    ///
    /// - Parameters:
    ///   - error: The real, un-wrapped error thrown by the auth backend (e.g.
    ///     the Stack SDK `OAuthError` carrying an `INVALID_APPLE_CREDENTIALS`
    ///     code), before it is mapped to a display-safe ``AuthError``.
    ///   - context: Structured key/value context (e.g. the flow name and OAuth
    ///     provider) attached to the captured event. Values are short,
    ///     non-sensitive strings safe to send to a telemetry backend.
    func report(error: any Error, context: AuthErrorContext)
}
