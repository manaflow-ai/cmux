import CmuxAuthRuntime
import Foundation
import Sentry
import StackAuth

/// The macOS ``AuthErrorReporting`` conformer: captures a failed sign-in to
/// Sentry with the auth flow, OAuth provider, and the underlying Stack error
/// code (e.g. `INVALID_APPLE_CREDENTIALS`).
///
/// Constructed at the app composition root and injected into the
/// ``AuthCoordinator``. Lives in the app target because `CmuxAuthRuntime` is a
/// shared low-level package that may not depend on Sentry (and iOS links none).
/// Honors the user's telemetry opt-out via `TelemetrySettings`.
struct SentryAuthErrorReporter: AuthErrorReporting {
    func report(error: any Error, context: AuthErrorContext) {
        guard TelemetrySettings.enabledForCurrentLaunch else { return }
        // Extract the backend code here (this layer imports StackAuth); the
        // coordinator stays SDK-free behind the AuthClient seam.
        let code = (error as? any StackAuthErrorProtocol)?.code
        var data: [String: Any] = ["flow": context.flow]
        if let provider = context.provider { data["provider"] = provider }
        if let code { data["code"] = code }

        _ = SentrySDK.capture(error: error) { scope in
            scope.setLevel(.error)
            scope.setTag(value: "auth", key: "category")
            scope.setContext(value: data, key: "auth_sign_in")
            if let code { scope.setTag(value: code, key: "auth_error_code") }
            if let provider = context.provider {
                scope.setTag(value: provider, key: "auth_provider")
            }
        }
    }
}
